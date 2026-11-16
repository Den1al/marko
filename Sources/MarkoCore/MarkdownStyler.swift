import Foundation
import Markdown

/// Turns a parsed document into a per-line StyleMap. Every range taken from the parser is checked
/// against the source characters; a line with a range that does not check out is emitted plain.
public enum MarkdownStyler {
    public static func style(_ source: String) -> StyleMap {
        style(source: source, document: Document(parsing: source))
    }

    static func style(source: String, document: Document) -> StyleMap {
        build(source: source, document: document).map
    }

    /// `isWhole` is false for a part of a text that does not hold its start, where "---" opens no front matter.
    static func build(source: String, document: Document, isWhole: Bool = true) -> (map: StyleMap, inconsistentLines: Set<Int>) {
        var builder = Builder(index: SourceIndex(source), isWhole: isWhole)
        builder.walkBlocks(document, chain: 0)
        builder.styleLines()
        builder.styleCode()
        builder.styleInlines()
        return (builder.finish(), builder.inconsistent)
    }

    /// Whether the line may start a link reference definition: behind anything that can be a block
    /// marker it opens a bracket, and the bracket's end is not on the line or has a colon behind
    /// it. Everything the parser takes for a definition starts on such a line; not every such line
    /// is one.
    static func mayDefineReference(_ units: ArraySlice<UInt16>) -> Bool {
        var i = units.startIndex
        let end = units.endIndex
        // The parser drops a byte order mark at the start of the text.
        while i < end, [0x20, 0x09, 0x3E, 0x2D, 0x2A, 0x2B, 0x2E, 0x29, 0xFEFF].contains(units[i]) || (0x30...0x39).contains(units[i]) { i += 1 }
        guard i < end, units[i] == 0x5B else { return false }
        var closes = false
        while i < end {
            if units[i] == 0x5C {
                i += 1
            } else if units[i] == 0x5D {
                if i + 1 < end, units[i + 1] == 0x3A { return true }
                closes = true
            }
            i += 1
        }
        return !closes
    }
}

private enum Leaf {
    case none, paragraph, rule, source
    case heading(level: Int, first: Int)
    case code(language: String?, first: Int, last: Int)
    case table(index: Int)
}

private struct InlineRoot {
    var node: any Markup
    /// From the line the parser counts from to the last line of text. For a table cell the last line
    /// is its row; the first differs from it only when the header row ends a paragraph.
    var lines: ClosedRange<Int>
    /// Column index when the root is a table cell.
    var cell: Int?
    /// For a body row cell, the 1-based column the table starts at. cmark measures every body row
    /// from there, whatever the row's own indentation.
    var tableColumn: Int?
}

/// A whole inline construct before it is split into per-line pieces.
private struct Span {
    var kind: InlineToken.Kind
    var range: Range<Int>
    var open: Range<Int>
    var close: Range<Int>
    var destination: String?

    var content: Range<Int> { open.upperBound..<close.lowerBound }
}

/// Bounds of the inline root being styled, plus what is needed to undo cmark's cell unescaping.
private struct InlineContext {
    var lines: ClosedRange<Int>
    var bounds: Range<Int>
    /// Bytes cmark skipped before the root's first line of text.
    var columnOffset = 0
    /// Added to every column of a body row cell.
    var columnShift = 0
    /// Offsets of the backslashes of "\|" in a table cell. cmark removes them before inline parsing,
    /// so every column after one is short by one.
    var escapes: [Int] = []

    func corrected(_ offset: Int) -> Int {
        var shift = 0
        while shift < escapes.count, escapes[shift] - shift < offset { shift += 1 }
        return offset + shift
    }
}

private struct Builder {
    let index: SourceIndex
    var units: [UInt16] { index.utf16 }

    var scanner = BlockPrefixScanner()
    var chains: [[BlockPrefixScanner.Container]] = [[]]
    /// Per list item, the length of the longest marker in its list, as numbered and as typed.
    var markerLengths: [Int] = []
    var lineChain: [Int]
    var leaves: [Leaf]
    var roots: [InlineRoot] = []
    var lines: [LineStyle] = []
    /// Per line, how many units cmark dropped before handing the rest to a paragraph: the block prefix
    /// and, unless the line is a lazy continuation, the whitespace after it.
    var skipped: [Int] = []
    var tables: [TableStyle] = []
    var spans: [Span] = []
    var inconsistent: Set<Int> = []
    let isWhole: Bool
    /// Where the inline root being walked stands: the last line number the parser claimed, the line
    /// that number really starts at, and how many lines below it a position has been carried.
    var sync = (claimed: 0, start: 0, carried: 0)

    init(index: SourceIndex, isWhole: Bool) {
        self.index = index
        self.isWhole = isWhole
        lineChain = Array(repeating: 0, count: index.lineCount)
        leaves = Array(repeating: .none, count: index.lineCount)
    }

    // MARK: Blocks

    /// 0-based lines a node covers. An end at column 1 means the node stopped on the line before.
    func lineSpan(_ node: any Markup) -> ClosedRange<Int>? {
        guard let range = node.range else { return nil }
        let first = range.lowerBound.line - 1
        var last = range.upperBound.line - 1
        if range.upperBound.column <= 1, last > first { last -= 1 }
        last = min(last, index.lineCount - 1)
        return first >= 0 && first <= last ? first...last : nil
    }

    mutating func enter(_ container: BlockPrefixScanner.Container, parent: Int, lines: ClosedRange<Int>) -> Int {
        chains.append(chains[parent] + [container])
        for line in lines { lineChain[line] = chains.count - 1 }
        return chains.count - 1
    }

    /// The length of the longest marker of an ordered list: of its last number as the parser counts
    /// them, or of a longer one as typed.
    func markerLength(of list: OrderedList) -> Int {
        list.children.reduce("\(list.startIndex + UInt(list.childCount) - 1).".count) { longest, item in
            guard let start = item.range?.lowerBound, let offset = index.offset(line: start.line, column: start.column) else { return longest }
            return max(longest, units[offset...].prefix { (0x30...0x39).contains($0) }.count + 1)
        }
    }

    /// `markerLength` is that of the list whose items `node` holds.
    mutating func walkBlocks(_ node: any Markup, chain: Int, markerLength: Int = 1) {
        for child in node.children {
            guard let span = lineSpan(child) else { continue }
            func mark(_ leaf: Leaf) { for line in span { leaves[line] = leaf } }
            switch child {
            case is BlockQuote:
                walkBlocks(child, chain: enter(.quote, parent: chain, lines: span))
            case let list as OrderedList:
                walkBlocks(child, chain: chain, markerLength: self.markerLength(of: list))
            case is UnorderedList:
                walkBlocks(child, chain: chain)
            case is ListItem:
                scanner.items.append(.init(line: span.lowerBound, isOrdered: node is OrderedList))
                markerLengths.append(markerLength)
                walkBlocks(child, chain: enter(.listItem(scanner.items.count - 1), parent: chain, lines: span))
            case is Paragraph:
                mark(.paragraph)
                roots.append(InlineRoot(node: child, lines: span))
            case let heading as Heading:
                mark(.heading(level: heading.level, first: span.lowerBound))
                roots.append(InlineRoot(node: child, lines: span))
            case let code as CodeBlock:
                // swift-markdown reports the whole info string.
                let language = code.language?.split(whereSeparator: \.isWhitespace).first.map(String.init)
                mark(.code(language: language, first: span.lowerBound, last: span.upperBound))
            case is ThematicBreak:
                mark(.rule)
            case is HTMLBlock:
                mark(.source)
            case let table as Table:
                addTable(table, lines: span)
            default:
                break
            }
        }
    }

    /// swift-markdown starts a table whose header row ends a paragraph at that paragraph, so the rows
    /// are placed from the other end: the delimiter row is the line before the first body row, or
    /// the last line.
    mutating func addTable(_ table: Table, lines span: ClosedRange<Int>) {
        let rows = table.body.children.compactMap { row in lineSpan(row).map { (node: row, line: $0.lowerBound) } }
        let header = (rows.first?.line ?? span.upperBound + 1) - 2
        guard header >= span.lowerBound, header < span.upperBound else { return }
        for line in span { leaves[line] = line < header ? .paragraph : .table(index: tables.count) }
        tables.append(TableStyle(lines: header..<span.upperBound + 1,
                                 alignments: table.columnAlignments.map {
                                     switch $0 {
                                     case .left: .left
                                     case .center: .center
                                     case .right: .right
                                     case nil: .none
                                     }
                                 }))
        for (column, cell) in table.head.children.enumerated() {
            roots.append(InlineRoot(node: cell, lines: span.lowerBound...header, cell: column))
        }
        for row in rows {
            for (column, cell) in row.node.children.enumerated() {
                roots.append(InlineRoot(node: cell, lines: row.line...row.line, cell: column,
                                        tableColumn: table.range?.lowerBound.column))
            }
        }
    }

    // MARK: Lines

    func isBlank(_ range: Range<Int>) -> Bool {
        range.allSatisfy { units[$0] == 0x20 || units[$0] == 0x09 }
    }

    mutating func styleLines() {
        lines.reserveCapacity(index.lineCount)
        let containers = chains.map { chain in
            chain.map { container -> LineStyle.Container in
                if case .listItem(let item) = container { .listItem(markerLength: markerLengths[item]) } else { .quote }
            }
        }
        var openFence: (unit: UInt16, length: Int)?
        /// First line of the setext heading whose underline has been passed.
        var underlined: Int?

        for line in 0..<index.lineCount {
            let content = index.contentRange(line)
            let end = NSMaxRange(content)
            let prefix = scanner.scan(units, from: content.location, to: end, line: line, chain: chains[lineChain[line]])
            let start = prefix.end
            var style = LineStyle(range: index.lineRange(line))
            style.containers = containers[lineChain[line]]
            style.prefixRange.length = start - content.location
            style.listMarkers = prefix.markers
            var textStart = start
            if !prefix.isLazy { while textStart < end, units[textStart] == 0x20 || units[textStart] == 0x09 { textStart += 1 } }
            skipped.append(textStart - content.location - (prefix.isLazy ? prefix.padding : 0))

            switch leaves[line] {
            case .none:
                // What the parser read without making a block of it is a link reference definition.
                style.kind = isBlank(start..<end) ? .blank : .source
            case .source:
                style.kind = .source
            case .paragraph:
                style.kind = .paragraph
            case .rule:
                style.kind = .rule
            case .heading(_, let first) where underlined == first:
                // The parser's range of a setext heading runs on to the end of the next line.
                style.kind = isBlank(start..<end) ? .blank : .paragraph
            case .heading(let level, let first):
                if line == first, let markers = atxMarkers(start, end) {
                    style.kind = .heading(level: level)
                    style.headingMarkers = markers
                } else if line > first, isSetextUnderline(start, end) {
                    style.kind = .headingUnderline(level: level)
                    underlined = first
                } else {
                    style.kind = .heading(level: level)
                }
            case .code(let language, let first, let last):
                let found = fence(start, end)
                if line == first {
                    openFence = found.map { ($0.unit, $0.length) }
                    style.kind = openFence == nil ? .codeBody(language: nil) : .codeFence(language: language, isClosing: false)
                } else if line == last, let open = openFence, let close = found,
                          close.unit == open.unit, close.length >= open.length, isBlank(close.end..<end) {
                    style.kind = .codeFence(language: nil, isClosing: true)
                } else {
                    style.kind = .codeBody(language: openFence == nil ? nil : language)
                }
                if openFence != nil {
                    style.fenceMarker = found.map { NSRange(location: $0.end - $0.length, length: $0.length) }
                } else {
                    // The indentation that makes the line code is a block marker like any other.
                    style.prefixRange.length = codeIndentEnd(start, end) - content.location
                }
            case .table(let table):
                let header = tables[table].lines.lowerBound
                if line != header + 1 {
                    style.kind = .tableRow(isHeader: line == header)
                    scanCells(start, end, into: &style)
                } else if isDelimiterRow(start, end) {
                    style.kind = .tableDelimiter(alignments: tables[table].alignments)
                    style.pipes = (start..<end).filter { units[$0] == 0x7C }
                } else {
                    inconsistent.formUnion(tables[table].lines)
                }
            }
            // Whatever the parser made of the line: its ranges after a fence inside a quote can be a line out.
            style.mayDefineReference = MarkdownStyler.mayDefineReference(units[content.location..<end])
            lines.append(style)
        }
    }

    /// Tokenizes each fenced block as one piece of code, so a comment or string can run over lines,
    /// and hands the tokens to the lines they lie on. Block prefixes are left out of the code.
    mutating func styleCode() {
        var first = 0
        while first < lines.count {
            guard case .codeBody(let language?) = lines[first].kind else {
                first += 1
                continue
            }
            var end = first
            var code: [UInt16] = []
            var starts: [Int] = []
            while end < lines.count, lines[end].kind == lines[first].kind {
                starts.append(code.count)
                code += units[NSMaxRange(lines[end].prefixRange)..<NSMaxRange(lines[end].range)]
                end += 1
            }
            var line = 0
            for token in CodeTokenizer.tokens(in: String(decoding: code, as: UTF16.self), language: language) {
                while line + 1 < starts.count, starts[line + 1] <= token.range.location { line += 1 }
                var piece = line
                while piece < starts.count, starts[piece] < NSMaxRange(token.range) {
                    let lower = max(token.range.location, starts[piece])
                    let upper = min(NSMaxRange(token.range), piece + 1 < starts.count ? starts[piece + 1] : code.count)
                    let offset = NSMaxRange(lines[first + piece].prefixRange) - starts[piece]
                    lines[first + piece].codeTokens.append(
                        CodeToken(range: NSRange(location: lower + offset, length: upper - lower), kind: token.kind))
                    piece += 1
                }
            }
            first = end
        }
    }

    /// The opening "#"s with the whitespace after them, and the closing sequence if there is one.
    func atxMarkers(_ start: Int, _ end: Int) -> [NSRange]? {
        var i = start
        while i < end, i - start < 3, units[i] == 0x20 { i += 1 }
        let hashes = i
        while i < end, units[i] == 0x23 { i += 1 }
        guard (1...6).contains(i - hashes), i == end || units[i] == 0x20 || units[i] == 0x09 else { return nil }
        while i < end, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
        let opening = NSRange(location: start, length: i - start)

        var j = end
        while j > i, units[j - 1] == 0x20 || units[j - 1] == 0x09 { j -= 1 }
        let closingEnd = j
        while j > i, units[j - 1] == 0x23 { j -= 1 }
        guard j < closingEnd else { return [opening] }
        if j == i { return [opening, NSRange(location: j, length: end - j)] }
        guard units[j - 1] == 0x20 || units[j - 1] == 0x09 else { return [opening] }
        while j > i, units[j - 1] == 0x20 || units[j - 1] == 0x09 { j -= 1 }
        return [opening, NSRange(location: j, length: end - j)]
    }

    func isSetextUnderline(_ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end, units[i] == 0x20 { i += 1 }
        guard i < end, units[i] == 0x3D || units[i] == 0x2D else { return false }
        let unit = units[i]
        while i < end, units[i] == unit { i += 1 }
        return isBlank(i..<end)
    }

    func isDelimiterRow(_ start: Int, _ end: Int) -> Bool {
        (start..<end).contains { units[$0] == 0x2D }
            && (start..<end).allSatisfy { [0x20, 0x09, 0x7C, 0x2D, 0x3A].contains(units[$0]) }
    }

    /// Lines of a leading "---" block closed by "---" or "...", which is shown as plain source.
    func frontMatterLineCount() -> Int {
        func isLine(_ line: Int, _ text: String) -> Bool {
            let content = index.contentRange(line)
            return units[content.location..<NSMaxRange(content)].elementsEqual(text.utf16)
        }
        guard index.lineCount > 1, isLine(0, "---") else { return 0 }
        return (1..<index.lineCount).first { isLine($0, "---") || isLine($0, "...") }.map { $0 + 1 } ?? 0
    }

    /// Where the four columns of indentation in front of indented code end.
    func codeIndentEnd(_ start: Int, _ end: Int) -> Int {
        var i = start, columns = 0
        while i < end, columns < 4, units[i] == 0x20 || units[i] == 0x09 {
            columns = units[i] == 0x09 ? 4 : columns + 1
            i += 1
        }
        return i
    }

    func fence(_ start: Int, _ end: Int) -> (unit: UInt16, length: Int, end: Int)? {
        var i = start
        while i < end, i - start < 3, units[i] == 0x20 { i += 1 }
        guard i < end, units[i] == 0x60 || units[i] == 0x7E else { return nil }
        let first = i
        while i < end, units[i] == units[first] { i += 1 }
        return i - first >= 3 ? (units[first], i - first, i) : nil
    }

    /// Splits a table row at pipes that are not directly preceded by a backslash, as cmark-gfm does.
    func scanCells(_ start: Int, _ end: Int, into style: inout LineStyle) {
        var i = start
        while i < end, units[i] == 0x20 || units[i] == 0x09 { i += 1 }
        if i < end, units[i] == 0x7C {
            style.pipes.append(i)
            i += 1
        }
        var cellStart = i
        func addCell(to cellEnd: Int) {
            var low = cellStart, high = cellEnd
            while low < high, units[low] == 0x20 || units[low] == 0x09 { low += 1 }
            while high > low, units[high - 1] == 0x20 || units[high - 1] == 0x09 { high -= 1 }
            style.cells.append(TableCell(range: NSRange(location: cellStart, length: cellEnd - cellStart),
                                         contentRange: NSRange(location: low, length: high - low)))
        }
        while i < end {
            if units[i] == 0x7C, units[i - 1] != 0x5C {
                addCell(to: i)
                style.pipes.append(i)
                cellStart = i + 1
            }
            i += 1
        }
        if !isBlank(cellStart..<end) { addCell(to: end) }
    }

    // MARK: Inlines

    mutating func styleInlines() {
        for root in roots {
            let row = lines[root.lines.upperBound]
            // From the line start: the text of a task item the parser missed begins at its checkbox.
            var context = InlineContext(
                lines: root.lines,
                bounds: index.lineRange(root.lines.lowerBound).location..<NSMaxRange(index.contentRange(root.lines.upperBound))
            )
            context.columnOffset = (root.node.range?.lowerBound.column ?? 1) - 1
            if let column = root.cell {
                guard case .tableRow = row.kind, column < row.cells.count else { continue }
                let cell = row.cells[column].range
                context.bounds = cell.location..<NSMaxRange(cell)
                context.escapes = context.bounds.dropLast().filter { units[$0] == 0x5C && units[$0 + 1] == 0x7C }
                if let tableColumn = root.tableColumn {
                    context.columnShift = skipped[root.lines.upperBound] - (tableColumn - 1)
                }
            }
            spans.removeAll(keepingCapacity: true)
            sync = (root.lines.lowerBound + 1, root.lines.lowerBound, 0)
            _ = walkInlines(root.node, from: context.bounds.lowerBound, context)
            for span in spans { emit(span) }
            emitEscapes(context)
        }
    }

    /// Adds a token for every backslash that escapes a punctuation character in the text of the
    /// root whose `spans` have just been collected. In code, an autolink or HTML a backslash is
    /// text; in a link's destination it is hidden or shown with the destination.
    mutating func emitEscapes(_ context: InlineContext) {
        let literals = spans.compactMap { span -> Range<Int>? in
            switch span.kind {
            case .code, .html: span.range
            case .link, .image: units[span.range.lowerBound] == 0x3C ? span.range : span.close
            default: nil
            }
        }
        for line in context.lines {
            var i = max(NSMaxRange(lines[line].prefixRange), context.bounds.lowerBound)
            let end = min(NSMaxRange(index.contentRange(line)), context.bounds.upperBound)
            while i + 1 < end {
                if let literal = literals.first(where: { $0.contains(i) }) {
                    i = literal.upperBound
                } else if units[i] == 0x5C, [0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E].contains(where: { $0.contains(units[i + 1]) }) {
                    // Behind the tokens that start before it, which keeps a parent before what it holds.
                    let place = lines[line].tokens.firstIndex { $0.range.location > i } ?? lines[line].tokens.count
                    lines[line].tokens.insert(InlineToken(
                        kind: .escape, range: NSRange(location: i, length: 2), markerRanges: [NSRange(location: i, length: 1)],
                        contentRange: NSRange(location: i + 1, length: 1)), at: place)
                    i += 2
                } else {
                    i += 1
                }
            }
        }
    }

    /// cmark computes columns as if every line of a paragraph had the first line's prefix, so later
    /// lines are re-based on what was really skipped there. It also does not start a new line at a
    /// backslash break or inside a link destination or title: it keeps counting columns on the line
    /// before, and every line number after that is one short. A column past the end of its line is
    /// therefore carried to the lines below, and later line numbers are moved down by as many.
    /// Positions must be asked for in document order.
    mutating func offset(_ location: SourceLocation, _ context: InlineContext) -> Int? {
        if location.line > sync.claimed {
            sync = (location.line, sync.start + location.line - sync.claimed + sync.carried, 0)
        }
        var line = sync.start
        guard location.line == sync.claimed, context.lines.contains(line) else { return nil }
        var column = location.column + context.columnShift
        if line > context.lines.lowerBound { column += skipped[line] - context.columnOffset }
        while line < context.lines.upperBound, column - 1 > index.utf8Length(line) {
            // cmark counts a line end as one column, CRLF included.
            column -= index.utf8Length(line) + 1
            line += 1
            column += skipped[line]
        }
        sync.carried = max(sync.carried, line - sync.start)
        guard let offset = index.offset(line: line + 1, column: column) else { return nil }
        let corrected = context.corrected(offset)
        return context.bounds.contains(corrected) || corrected == context.bounds.upperBound ? corrected : nil
    }

    /// Collects the spans below `node`, whose content starts at `lower`, and returns the end of its
    /// last child. A child whose range does not match the source is dropped with its subtree and
    /// the lines it reaches are marked inconsistent.
    mutating func walkInlines(_ node: any Markup, from lower: Int, _ context: InlineContext) -> Int {
        var last = lower
        for child in node.children {
            // swift-markdown gives no range to a strikethrough whose closer is on a later line and
            // further left than its opener. Its first child says where it starts. Breaks have no range either.
            let isUnranged = child.range == nil && child is Strikethrough
            guard let position = (isUnranged ? child.child(at: 0) : child)?.range?.lowerBound else {
                if isUnranged { inconsistent.formUnion(context.lines) }
                continue
            }
            guard var start = offset(position, context) else {
                inconsistent.formUnion(context.lines)
                continue
            }
            if isUnranged { while start > lower, units[start - 1] == 0x7E { start -= 1 } }
            // Nested delimiters are reported with the range of the outermost one.
            start = max(start, lower)

            let slot = spans.count
            var span: Span?
            switch child {
            case is Strong:
                span = delimited(.strong, child, from: start, length: 2, units: [0x2A, 0x5F], context)
            case is Emphasis:
                span = delimited(.emphasis, child, from: start, length: 1, units: [0x2A, 0x5F], context)
            case is Strikethrough:
                let isDouble = start + 1 < units.count && units[start + 1] == 0x7E
                span = delimited(.strikethrough, child, from: start, length: isDouble ? 2 : 1, units: [0x7E], context)
            case is InlineCode:
                span = codeSpan(from: start, limit: context.bounds.upperBound)
                if let span { spans.append(span) }
            case let link as Link:
                span = bracketed(.link, child, from: start, destination: link.destination ?? "", context)
            case let image as Image:
                span = bracketed(.image, child, from: start, destination: image.source ?? "", context)
            case is InlineHTML:
                if let end = child.range.flatMap({ offset($0.upperBound, context) }), start < end {
                    span = Span(kind: .html, range: start..<end, open: start..<start, close: end..<end)
                }
                if let span { spans.append(span) }
            default:
                if let end = child.range.flatMap({ offset($0.upperBound, context) }) {
                    last = max(last, end)
                } else {
                    inconsistent.formUnion(context.lines)
                }
                continue
            }
            guard let span, startsAfterPrefix(span.range) else {
                spans.removeSubrange(slot...)
                if let first = index.lineIndex(containing: start) {
                    inconsistent.formUnion(first...max(first, min(sync.start + sync.carried, context.lines.upperBound)))
                }
                continue
            }
            last = max(last, span.range.upperBound)
        }
        return last
    }

    func startsAfterPrefix(_ range: Range<Int>) -> Bool {
        guard !range.isEmpty, let first = index.lineIndex(containing: range.lowerBound),
              let last = index.lineIndex(containing: range.upperBound - 1) else { return false }
        return range.lowerBound >= NSMaxRange(lines[first].prefixRange)
            && range.upperBound <= NSMaxRange(index.contentRange(last))
    }

    /// Strong, emphasis and strikethrough. The closer is the delimiter run after the last child: the
    /// parser's end is shared by nested delimiters and is on the wrong line for a multi-line strikethrough.
    mutating func delimited(_ kind: InlineToken.Kind, _ node: any Markup, from start: Int, length: Int,
                            units allowed: [UInt16], _ context: InlineContext) -> Span? {
        let slot = spans.count
        let open = start..<start + length
        // Holds the place in front of the children.
        spans.append(Span(kind: kind, range: open, open: open, close: open))
        let inner = walkInlines(node, from: min(open.upperBound, context.bounds.upperBound), context)

        func closes(at end: Int) -> Bool {
            end <= context.bounds.upperBound && end - start >= 2 * length
                && (end - length..<end).allSatisfy { units[$0] == units[start] }
        }
        var end = inner + length
        // A last child without a range, which is what text ending in a stray "~" gets, leaves the parser's end.
        if !closes(at: end), let claimed = node.range.flatMap({ offset($0.upperBound, context) }) { end = claimed }
        guard closes(at: end), allowed.contains(units[start]), open.allSatisfy({ units[$0] == units[start] }) else { return nil }
        spans[slot] = Span(kind: kind, range: start..<end, open: open, close: end - length..<end)
        return spans[slot]
    }

    /// The backtick runs are counted from the source; the parser's end is wrong for multi-line spans in quotes.
    func codeSpan(from start: Int, limit: Int) -> Span? {
        var i = start
        while i < limit, units[i] == 0x60 { i += 1 }
        let length = i - start
        guard length > 0 else { return nil }
        while i < limit {
            guard units[i] == 0x60 else { i += 1; continue }
            let run = i
            while i < limit, units[i] == 0x60 { i += 1 }
            if i - run == length {
                return Span(kind: .code, range: start..<i, open: start..<start + length, close: run..<i)
            }
        }
        return nil
    }

    /// Links and images: "[text](url "title")", "[text][ref]", "[text]" and "<autolink>".
    mutating func bracketed(_ kind: InlineToken.Kind, _ node: any Markup, from start: Int, destination: String,
                            _ context: InlineContext) -> Span? {
        let slot = spans.count
        let open = start..<start + (kind == .image ? 2 : 1)
        spans.append(Span(kind: kind, range: open, open: open, close: open))
        var textEnd = walkInlines(node, from: min(open.upperBound, context.bounds.upperBound), context)
        guard let end = node.range.flatMap({ offset($0.upperBound, context) }), open.upperBound < end else { return nil }

        var span = Span(kind: kind, range: start..<end, open: open, close: end - 1..<end, destination: destination)
        if kind == .link, units[start] == 0x3C {
            guard units[end - 1] == 0x3E else { return nil }
        } else {
            guard units[open.upperBound - 1] == 0x5B, kind == .link || units[start] == 0x21 else { return nil }
            // A soft break before "]" leaves only whitespace and quote markers in between.
            while textEnd < end, [0x20, 0x09, 0x0A, 0x0D, 0x3E].contains(units[textEnd]) { textEnd += 1 }
            let isInline = textEnd + 2 < end && units[textEnd + 1] == 0x28
            guard textEnd < end, units[textEnd] == 0x5D, units[end - 1] == (isInline ? 0x29 : 0x5D) else { return nil }
            span.close = textEnd..<end
        }
        spans[slot] = span
        return span
    }

    /// Appends the piece of `span` on each line it crosses to that line's tokens.
    mutating func emit(_ span: Span) {
        guard let first = index.lineIndex(containing: span.range.lowerBound),
              let last = index.lineIndex(containing: span.range.upperBound - 1) else { return }
        let whole = NSRange(location: span.range.lowerBound, length: span.range.count)
        for line in first...last {
            let visible = NSMaxRange(lines[line].prefixRange)..<max(NSMaxRange(lines[line].prefixRange), NSMaxRange(index.contentRange(line)))
            func onLine(_ range: Range<Int>) -> NSRange {
                let clamped = range.clamped(to: visible)
                return NSRange(location: clamped.lowerBound, length: clamped.count)
            }
            let markers = [span.open, span.close].map(onLine).filter { $0.length > 0 }
            let content = onLine(span.content)
            guard !markers.isEmpty || content.length > 0 else { continue }
            lines[line].tokens.append(InlineToken(
                kind: span.kind, range: whole, markerRanges: markers, contentRange: content, destination: span.destination
            ))
        }
    }

    /// Inconsistent lines become plain lines and front matter source lines. So does every line of
    /// a table that has one, which leaves no table with a row that is not one.
    func finish() -> StyleMap {
        let frontMatter = 0..<(isWhole ? frontMatterLineCount() : 0)
        var plain = inconsistent.union(frontMatter)
        var map = StyleMap()
        map.lines = lines
        map.hasReferences = lines.contains(where: \.mayDefineReference)
        map.tables = tables.filter { table in
            guard table.lines.contains(where: plain.contains) else { return true }
            plain.formUnion(table.lines)
            return false
        }
        for line in plain {
            map.lines[line] = LineStyle(range: lines[line].range)
            map.lines[line].mayDefineReference = lines[line].mayDefineReference
            if frontMatter.contains(line) { map.lines[line].kind = .source }
        }
        return map
    }
}
