import AppKit
import MarkoCore

/// Builds the display paragraph for each source line. Storage is never changed: a display paragraph
/// has the same length as its source line, and syntax is hidden by giving it a near-zero font.
final class ParagraphRenderer: NSObject, NSTextContentStorageDelegate, NSTextLayoutManagerDelegate {
    var map = StyleMap() { didSet { grids = [:] } }
    /// The text has changed since `map` was made. Until the reparse every paragraph asked for shows
    /// raw: an old line can match a new paragraph's range and would hide the wrong characters.
    var isStale = false
    /// The selection the reveal state is computed from. A token or heading it touches shows its markers.
    var revealSelection = NSRange(location: 0, length: 0) { didSet { grids = [:] } }
    /// The width of the text column, which a picture is scaled down to and which a table whose
    /// cells wrap is as wide as.
    private(set) var columnWidth = CGFloat.greatestFiniteMagnitude
    /// The room for a table's grid, which is the text container's width: the page between the
    /// paddings at the window's edges, so more than the column in a wide window. A table that
    /// needs more wraps its cells' text.
    private(set) var tableRoom = CGFloat.greatestFiniteMagnitude
    /// Where the text column starts in the text container: in the middle of one that is wider.
    /// A paragraph style's indents and tab stops are measured from the container, everything
    /// else that says where something stands from the column.
    var columnOrigin: CGFloat { tableRoom > columnWidth ? theme.columnOrigin(inContainer: tableRoom) : 0 }
    /// The link under the mouse while Command is held, which shows underlined.
    var hoveredLink: NSRange?
    let images = ImageCache()

    private let theme = Theme.standard
    /// How the tables asked about since the map, the reveal selection or the room last changed show,
    /// by header line; nil for one that shows as its source.
    private var grids: [Int: TableGrid?] = [:]
    /// Cell widths by row text and reveal state, so that a row is measured once however often its
    /// text comes back (undo, a parse of the whole text).
    private let rowWidths = NSCache<NSString, NSArray>()
    /// The lines each cell of a row of wrapping cells takes, by the cells' widths and the row's
    /// text as it shows, for the rows that TextKit laid out with other lines than were counted.
    private let lineCounts = NSCache<NSString, NSArray>()
    /// The same widths with every marker hidden, by line of the map, at the normal and at the
    /// compact size; nil for a line that was not measured. MEASURED: looking 2,000 rows up by
    /// their text, several times per key, was half of a key's time in such a table. `keepWidths`
    /// keeps these in step with the map.
    private var hiddenWidths: [[[CGFloat]?]] = [[], []]
    /// What each cell of a table row needs where its text may wrap, by line of the map like
    /// `hiddenWidths`: the width of its longest line (a cell's "<br>" ends one), of its longest
    /// word and of all its lines together, at the normal size with every marker hidden.
    private var needs: [[(line: CGFloat, word: CGFloat, all: CGFloat)]?] = []
    /// Whether a table has shown with wrapping cells in this editor; until then no selection is
    /// looked at for one (GridLayoutManager) and Up and Down are the text view's own.
    private(set) var hasWrappedRows = false
    /// A table too wide for the window even at the compact size wraps its cells' text. That rests
    /// on behaviour of TextKit 2 that is observed, not documented (OSCanaryTests has what it is):
    /// should a system break it, false here shows such tables as their source again.
    static var wrapsWideTables = true

    /// The text TextKit has asked for display paragraphs of, which it keeps: only they can be out of date.
    private var rendered = IndexSet()
    /// The text whose display paragraphs are to be asked for again before they are next shown;
    /// see `EditorController.nudge`.
    var behind = IndexSet()

    /// The paragraphs TextKit has of `range` are out of date.
    func fallBehind(_ range: NSRange) {
        for part in rendered.rangeView(of: range.location..<NSMaxRange(range)) { behind.insert(integersIn: part) }
    }

    /// Keeps both on their text through an edit that put other text in the place of `length`
    /// units at `location`; the edit's own paragraphs are asked for anyway.
    func shiftRendered(editAt location: Int, replacing length: Int, delta: Int) {
        for keyPath in [\ParagraphRenderer.rendered, \.behind] {
            self[keyPath: keyPath].remove(integersIn: location..<location + length)
            self[keyPath: keyPath].shift(startingAt: location + length, by: delta)
        }
    }

    // MARK: reveal

    /// Both boundaries count, so a marker reveals the moment the caret reaches it.
    private func touches(_ range: NSRange, _ selection: NSRange) -> Bool {
        selection.location <= NSMaxRange(range) && NSMaxRange(selection) >= range.location
    }

    /// An image shows as a picture where it is whole on a line of text. Anywhere else it stays source.
    private func showsPicture(_ token: InlineToken, on line: LineStyle) -> Bool {
        guard token.kind == .image, NSLocationInRange(token.range.location, line.range),
              NSMaxRange(token.range) <= NSMaxRange(line.range) else { return false }
        switch line.kind {
        case .paragraph, .heading: return true
        default: return false
        }
    }

    /// Whether `selection` shows the source of `token`: where it touches it. An HTML tag is only
    /// shown by the caret or by an end of the selection: a "<br>" that a selection merely covers
    /// stays the line break it is in a cell, and the rows keep their lines under the selection.
    private func reveals(_ selection: NSRange, _ token: InlineToken) -> Bool {
        guard token.kind == .html, selection.length > 0 else { return touches(token.range, selection) }
        return [selection.location, NSMaxRange(selection)].contains { touches(token.range, NSRange(location: $0, length: 0)) }
    }

    /// With `touched` false the selection reveals nothing: only what always shows its source does.
    private func isRevealed(_ token: InlineToken, on line: LineStyle, touched: Bool = true) -> Bool {
        token.kind == .image && !showsPicture(token, on: line) || touched && reveals(revealSelection, token)
    }

    /// The lines that show a picture, to render again when an image arrives or the column's width changes.
    func pictureRanges() -> [NSRange] {
        map.lines.filter { line in line.tokens.contains { showsPicture($0, on: line) } }.map(\.range)
    }

    /// The lines among those touching `range` that show `picture` `width` points wide. Only
    /// they are drawn again when its pixels at that size arrive: a line that shows it at another
    /// size would ask for that size again, and where both do not fit in memory, for ever.
    func ranges(showing picture: ImageCache.Picture, width: CGFloat, in range: NSRange) -> [NSRange] {
        let span = lines(touching: range)
        return span.filter { index in
            let line = map.lines[index]
            return line.tokens.contains { token in
                guard showsPicture(token, on: line), case .image(let shown) = images.entry(for: token.destination ?? ""),
                      shown === picture else { return false }
                return abs(shownSize(of: shown, room: (columnWidth - columns(ofLineAt: index).indent).rounded(.down)).width - width) < 1
            }
        }.map { map.lines[$0].range }
    }

    /// Lets go of the images that no line of the map shows any more, such as those of every
    /// address passed through while one is typed.
    func forgetUnusedImages() {
        guard !images.isEmpty else { return }
        images.keep(Set(map.lines.lazy.flatMap(\.tokens).filter { $0.kind == .image }.compactMap(\.destination)))
    }

    /// Sizes have changed: everything measured is measured again.
    func forgetMeasurements() {
        rowWidths.removeAllObjects()
        lineCounts.removeAllObjects()
        hiddenWidths = [[], []]
        needs = []
        images.forgetPixels()
        grids = [:]
        checkboxImages = []
    }

    /// The range whose touch reveals the line's own markers: the content of an ATX heading, a rule,
    /// a fence line, or a setext underline together with the heading line above it.
    private func lineRevealRange(_ index: Int, in text: NSString) -> NSRange? {
        let line = map.lines[index]
        // The map can be older than the text while a large document waits for its reparse.
        guard line.range.location <= text.length else { return nil }
        var end = min(NSMaxRange(line.range), text.length)
        while end > line.range.location, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        switch line.kind {
        case .heading where !line.headingMarkers.isEmpty, .rule, .codeFence:
            return NSRange(location: line.range.location, length: end - line.range.location)
        case .headingUnderline:
            let start = index > 0 ? map.lines[index - 1].range.location : line.range.location
            return NSRange(location: start, length: end - start)
        default:
            return nil
        }
    }

    /// Lines whose range, terminator included, touches `range`.
    private func lines(touching range: NSRange) -> Range<Int> {
        var low = 0, high = map.lines.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(map.lines[mid].range) < range.location { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < map.lines.count, map.lines[end].range.location <= NSMaxRange(range) { end += 1 }
        return low..<end
    }

    /// What `selection` reveals, as the ranges to re-render when that changes.
    func revealedRanges(for selection: NSRange, in text: NSString) -> Set<NSRange> {
        var result: Set<NSRange> = []
        let span = lines(touching: selection)
        // One more line, because a setext underline is revealed from the line above it.
        for index in span.lowerBound..<min(span.upperBound + 1, map.lines.count) {
            for token in map.lines[index].tokens where reveals(selection, token) {
                result.insert(token.range)
            }
            if let range = lineRevealRange(index, in: text), touches(range, selection) {
                result.insert(range)
            }
        }
        return result
    }

    /// What to re-render when what is revealed in `range` changes: revealed markers widen their
    /// cell, which moves the columns of every row of a table.
    /// Not where the cells wrap: there the columns go by what the cells hold with every marker hidden.
    func restyleRange(for range: NSRange, in text: NSString) -> NSRange {
        guard let index = map.lineIndex(containing: range.location), let table = map.table(atLine: index),
              grid(ofTableAt: index, in: text)?.wraps != true else { return range }
        return self.range(of: table)
    }

    // MARK: tables

    private func range(of table: TableStyle) -> NSRange {
        NSUnionRange(map.lines[table.lines.lowerBound].range, map.lines[table.lines.upperBound - 1].range)
    }

    /// The widths of the row's cells as they show at the normal or the compact size: markers hidden,
    /// except, with `touched`, those of the tokens the selection touches. Measured with the styling
    /// the row is displayed with.
    private func cellWidths(ofRowAt index: Int, in text: NSString, isCompact: Bool, touched: Bool) -> [CGFloat] {
        let line = map.lines[index]
        guard NSMaxRange(line.range) <= text.length else { return [] }
        // A tab in a cell shows as a space: as a tab it would jump to the next column's stop.
        let source = text.substring(with: line.range).replacingOccurrences(of: "\t", with: " ")
        let state = line.tokens.map { isRevealed($0, on: line, touched: touched) ? "r" : "h" }.joined()
        let key = "\(line.kind == .tableRow(isHeader: true) ? "H" : "B")\(isCompact ? "c" : "n")\(state)\n\(source)" as NSString
        if let widths = rowWidths.object(forKey: key) as? [CGFloat] { return widths }
        let row = NSMutableAttributedString(string: source, attributes: [.font: cellFont(of: line, isCompact: isCompact)])
        styleTokens(of: line, in: row, touched: touched)
        showIcons(in: row)
        let widths = line.cells.map { cell in
            let range = NSRange(location: cell.range.location - line.range.location, length: cell.range.length)
            return row.attributedSubstring(from: range).size().width.rounded(.up)
        }
        rowWidths.setObject(widths as NSArray, forKey: key)
        return widths
    }

    private func cellFont(of line: LineStyle, isCompact: Bool) -> NSFont {
        theme.tableFont(isHeader: line.kind == .tableRow(isHeader: true), isCompact: isCompact)
    }

    /// The map has been brought up to date with edits, before which it had `count` lines: the
    /// text in `edited` is new and the lines in `changed` have other styles. What was measured of
    /// every other line still holds, at the place the line is now.
    func keepWidths(editing edited: NSRange, changing changed: Range<Int>, lineCountBefore count: Int) {
        var new = lines(touching: edited)
        if !changed.isEmpty { new = min(new.lowerBound, changed.lowerBound)..<max(new.upperBound, changed.upperBound) }
        let oldEnd = new.upperBound - (map.lines.count - count)
        func keep<Row>(_ rows: inout [Row?]) {
            if rows.count == count, new.lowerBound <= oldEnd, oldEnd <= count {
                rows.replaceSubrange(new.lowerBound..<oldEnd, with: repeatElement(nil, count: new.count))
            } else {
                rows = []
            }
        }
        for size in hiddenWidths.indices { keep(&hiddenWidths[size]) }
        keep(&needs)
    }

    /// The "<br>" tags on a table row's line, in any spelling: a line break inside a cell, where cells wrap.
    private func lineBreaks(of line: LineStyle, in text: NSString) -> [InlineToken] {
        line.tokens.filter {
            $0.kind == .html && NSMaxRange($0.range) <= text.length
                && ["<br>", "<br/>", "<br />"].contains(text.substring(with: $0.range).lowercased())
        }
    }

    /// What the cells of the row at `index` need where their text wraps. One line of text is set
    /// for the whole row and everything is read from it.
    private func cellNeeds(ofRowAt index: Int, in text: NSString) -> [(line: CGFloat, word: CGFloat, all: CGFloat)] {
        let line = map.lines[index]
        guard NSMaxRange(line.range) <= text.length else { return [] }
        let source = text.substring(with: line.range).replacingOccurrences(of: "\t", with: " ") as NSString
        let row = NSMutableAttributedString(string: source as String, attributes: [.font: cellFont(of: line, isCompact: false)])
        styleTokens(of: line, in: row, touched: false)
        showIcons(in: row)
        let set = CTLineCreateWithAttributedString(row), start = line.range.location
        func width(_ from: Int, _ to: Int) -> CGFloat {
            (CTLineGetOffsetForStringIndex(set, to - start, nil) - CTLineGetOffsetForStringIndex(set, from - start, nil)).rounded(.up)
        }
        let breaks = lineBreaks(of: line, in: text).map(\.range)
        return line.cells.map { cell in
            var need = (line: CGFloat(0), word: CGFloat(0), all: CGFloat(0))
            let end = NSMaxRange(cell.contentRange)
            var from = cell.contentRange.location
            for stop in breaks.filter({ $0.location >= from && NSMaxRange($0) <= end }) + [NSRange(location: end, length: 0)] {
                var word = from, last = from
                for offset in from...stop.location {
                    let unit = offset < stop.location ? source.character(at: offset - start) : 0x20
                    // Text may also break between the characters of Chinese, Japanese and Korean;
                    // not inside what is two units, as an emoji is.
                    guard unit == 0x20 || Self.ideographs.contains(where: { $0.contains(unit) }) else { continue }
                    if offset > word {
                        need.word = max(need.word, width(word, offset))
                        last = offset
                    }
                    word = unit == 0x20 ? offset + 1 : offset
                }
                // Without the blanks around it.
                var first = from
                while first < last, source.character(at: first - start) == 0x20 { first += 1 }
                need.line = max(need.line, width(first, last))
                need.all += width(first, last)
                from = NSMaxRange(stop)
            }
            return need
        }
    }

    /// The UTF-16 units of Chinese, Japanese and Korean writing, between which a line may break.
    private static let ideographs: [ClosedRange<unichar>] = [0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF]

    /// The column edges of a regular table from its own left edge.
    private func edges(of table: TableStyle, in text: NSString, isCompact: Bool, touched: Bool) -> [CGFloat] {
        var widths = [CGFloat](repeating: theme.tableMinimumCellWidth, count: table.alignments.count)
        let size = isCompact ? 1 : 0
        if hiddenWidths[size].count != map.lines.count { hiddenWidths[size] = Array(repeating: nil, count: map.lines.count) }
        // Only a row the selection touches can show a marker.
        let revealing = touched ? lines(touching: revealSelection) : 0..<0
        for index in table.lines where index != table.lines.lowerBound + 1 {
            let row: [CGFloat]
            if revealing.contains(index) {
                row = cellWidths(ofRowAt: index, in: text, isCompact: isCompact, touched: true)
            } else if let known = hiddenWidths[size][index] {
                // In debug builds every kept row is checked against its text, as `restyle` is against the whole parse.
                assert(known == cellWidths(ofRowAt: index, in: text, isCompact: isCompact, touched: false), "a kept row width is not its line's")
                row = known
            } else {
                row = cellWidths(ofRowAt: index, in: text, isCompact: isCompact, touched: false)
                hiddenWidths[size][index] = row
            }
            for (column, width) in row.enumerated() { widths[column] = max(widths[column], width) }
        }
        let padding = theme.tableCellPadding(isCompact: isCompact).width
        return widths.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1 + 2 * padding) }
    }

    /// The column edges, from its own left edge, of a regular table that is `room` wide and whose
    /// cells wrap. A column whose longest line fits what an even split of the room gives it
    /// keeps its natural width; the others share the rest by how much text they hold, none
    /// narrower than its longest word or than `tableWrappingCellWidth`. Where that does not
    /// fit, none is narrower than its longest word; and where not even that fits, the columns
    /// with the longest words give way and only their words break. Nil for a table with more
    /// columns than fit the room at `tableMinimumCellWidth`.
    private func wrappedEdges(of table: TableStyle, in text: NSString, room: CGFloat) -> [CGFloat]? {
        let count = table.alignments.count, padding = theme.tableCellPadding.width
        let content = room - CGFloat(count) * 2 * padding
        guard content >= CGFloat(count) * theme.tableMinimumCellWidth else { return nil }
        var natural = [CGFloat](repeating: theme.tableMinimumCellWidth, count: count), word = natural
        var held = natural
        if needs.count != map.lines.count { needs = Array(repeating: nil, count: map.lines.count) }
        for index in table.lines where index != table.lines.lowerBound + 1 {
            let row = needs[index] ?? cellNeeds(ofRowAt: index, in: text)
            needs[index] = row
            for (column, need) in row.enumerated() {
                natural[column] = max(natural[column], need.line)
                word[column] = max(word[column], need.word)
                held[column] = max(held[column], need.all)
            }
        }
        // A word wider than half the table breaks rather than take the room from every other column.
        func widths(atLeast floor: CGFloat) -> [CGFloat] { zip(natural, word).map { min($0, max(min($1, content / 2), floor)) } }
        var least = widths(atLeast: theme.tableWrappingCellWidth)
        if least.reduce(0, +) > content { least = widths(atLeast: 0) }
        return Self.wrappedWidths(natural: natural, least: least, held: held, room: content)
            .reduce(into: [0]) { $0.append($0[$0.count - 1] + $1 + 2 * padding) }
    }

    /// How columns share `room`: each has a `natural` width, that of its longest line, can do
    /// with `least`, and has `held` as the width of all the text of its fullest cell. The long
    /// ones get the least they can do with and share what is left by how much more they hold,
    /// which is how a web browser does it: their cells then come out about as high as one another.
    /// Where not even the least fits, the columns that need the most are cut down to one width.
    nonisolated static func wrappedWidths(natural: [CGFloat], least: [CGFloat], held: [CGFloat], room: CGFloat) -> [CGFloat] {
        /// The value up to `limit` at which the widths fill the room, found by halving; a hair
        /// over rather than under it, which the rounding down of the widths takes off again.
        func most(upTo limit: CGFloat, _ widths: (CGFloat) -> [CGFloat]) -> CGFloat {
            var low: CGFloat = 0, high = limit
            guard widths(limit).reduce(0, +) > room else { return limit }
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if widths(middle).reduce(0, +) > room { high = middle } else { low = middle }
            }
            return high
        }
        guard least.reduce(0, +) < room else {
            let cut = most(upTo: max(room, 0)) { level in least.map { min($0, level) } }
            return least.map { min($0, cut).rounded(.down) }
        }
        let columns = natural.indices
        let even = most(upTo: room) { level in columns.map { min(natural[$0], max(least[$0], level)) } }
        func widths(_ share: CGFloat) -> [CGFloat] {
            columns.map { natural[$0] <= even ? natural[$0] : min(natural[$0], least[$0] + share * max(held[$0] - least[$0], 0)) }
        }
        return widths(most(upTo: 1, widths)).map { $0.rounded(.down) }
    }

    /// How the table that the line at `index` belongs to shows as a grid, with its column edges from
    /// the text column's left edge. Nil when it shows as source: no table, not a regular one, or
    /// one with more columns than there is room for.
    /// A grid of single lines when that fits the room, at the normal or else at the compact
    /// size, which is judged with every marker hidden, so that markers revealed at the caret
    /// never change the kind of grid; while they show, such a grid is as wide as they need. A
    /// table too wide for that wraps its cells' text in columns that share the room.
    /// The room is the page: a table that is wider than the text column goes on beside it, in
    /// the middle of the page. One in a list or a quote starts at its indent as the text
    /// there does and goes on to the right.
    func grid(ofTableAt index: Int, in text: NSString) -> TableGrid? {
        guard !isStale, let table = map.table(atLine: index) else { return nil }
        let header = table.lines.lowerBound
        if let known = grids[header] { return known }
        var grid: TableGrid?
        if map.isRegular(table) {
            let indent = columns(ofLineAt: header).indent, origin = columnOrigin
            let room = indent > 0 ? tableRoom - origin - indent : tableRoom
            /// Where a grid of `width` starts. That of a single-line grid is its width with every
            /// marker hidden, so that it stands still while markers show. One wider than the
            /// column reaches as far out of it on both sides, as far as the page goes on the
            /// left: its place goes by where the column stands, like everything else in a
            /// paragraph, and so only changes when all paragraphs are asked for again.
            func left(_ width: CGFloat) -> CGFloat {
                indent > 0 || width <= columnWidth ? indent : -min(origin, ((width - columnWidth) / 2).rounded(.up))
            }
            func width(isCompact: Bool) -> CGFloat { edges(of: table, in: text, isCompact: isCompact, touched: false).last ?? 0 }
            if let isCompact = [false, true].first(where: { width(isCompact: $0) <= room }) {
                let left = left(width(isCompact: isCompact))
                grid = TableGrid(edges: edges(of: table, in: text, isCompact: isCompact, touched: true).map { $0 + left }, isCompact: isCompact)
            } else if Self.wrapsWideTables, let edges = wrappedEdges(of: table, in: text, room: room) {
                let left = left(edges.last ?? 0)
                grid = TableGrid(edges: edges.map { $0 + left }, isCompact: false, wraps: true)
                hasWrappedRows = true
            }
        }
        grids[header] = grid
        return grid
    }

    /// What the lines of the table that the line at `index` is in share: a line that has not
    /// changed itself shows as it did for as long as this is the same. Nil outside a table.
    func look(ofTableAt index: Int, in text: NSString) -> TableLook? {
        guard !isStale, let table = map.table(atLine: index) else { return nil }
        return TableLook(lines: table.lines, alignments: table.alignments, grid: grid(ofTableAt: index, in: text))
    }

    /// The tables that show differently (another kind of grid, or wrapping cells in columns of
    /// other widths; not the same grid at another place) when the room for a table becomes
    /// `room` wide and the text column `column`, which they then are.
    func tablesChangingDisplay(room: CGFloat, column: CGFloat, in text: NSString) -> [NSRange] {
        // A table that has no measured row has not been shown since its text or the sizes last
        // changed: it is judged when it is asked for. MEASURED: judging every table of a document
        // here measured every row of each at open, 17 ms of the 170 ms for 600 KB of mixed text.
        let widths = hiddenWidths[0].count == map.lines.count ? hiddenWidths[0] : []
        let shown = map.tables.filter { table in !widths.isEmpty && table.lines.contains { widths[$0] != nil } }
        let before = shown.map { grid(ofTableAt: $0.lines.lowerBound, in: text) }
        (tableRoom, columnWidth, grids) = (room, column, [:])
        func shape(_ grid: TableGrid?) -> TableGrid? {
            guard var grid, let left = grid.edges.first else { return grid }
            grid.edges = grid.edges.map { $0 - left }
            return grid
        }
        return zip(shown, before).compactMap { table, old in
            shape(grid(ofTableAt: table.lines.lowerBound, in: text)) != shape(old) ? range(of: table) : nil
        }
    }

    /// In a row of a grid whose cells wrap, what stands hidden in front of each cell's text: the
    /// pipe before the cell and the blanks behind that pipe, and for the first cell the line's
    /// block markers too. An empty cell keeps its blanks, which are where its caret stands. Nil
    /// for any other line.
    func cellLeads(ofLineAt index: Int, in text: NSString) -> [NSRange]? {
        let line = map.lines[index]
        guard case .tableRow = line.kind, grid(ofTableAt: index, in: text)?.wraps == true else { return nil }
        return line.cells.enumerated().map { column, cell in
            let start = column == 0 ? line.range.location : line.pipes[column]
            return NSRange(location: start, length: (cell.contentRange.length > 0 ? cell.contentRange.location : line.pipes[column] + 1) - start)
        }
    }

    /// One stop for each pipe of a row: where its column's text starts, ends or is centred, and for
    /// the last pipe the table's right edge.
    /// `stops`, which are from the column's left edge, as a paragraph style wants them: from the
    /// container's. That goes for the stops a style has by itself as well. MEASURED: left where
    /// they were, with the column more than 336 points into the page, a tab had no stop to go to
    /// on any line, and its paragraph and everything below it was not laid out.
    private func tabStops(_ stops: [NSTextTab], in paragraph: NSMutableAttributedString) -> [NSTextTab] {
        let origin = columnOrigin
        guard origin > 0, paragraph.mutableString.range(of: "\t", options: .literal).location != NSNotFound else { return stops }
        return stops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + origin) }
    }

    private func tabStops(_ grid: TableGrid, alignments: [ColumnAlignment]) -> [NSTextTab] {
        let padding = theme.tableCellPadding(isCompact: grid.isCompact).width, edges = grid.edges
        return alignments.enumerated().map { column, alignment in
            switch alignment {
            case .right: NSTextTab(textAlignment: .right, location: edges[column + 1] - padding)
            case .center: NSTextTab(textAlignment: .center, location: (edges[column] + edges[column + 1]) / 2)
            case .left, .none: NSTextTab(textAlignment: .left, location: edges[column] + padding)
            }
        } + [NSTextTab(textAlignment: .left, location: edges[alignments.count])]
    }

    /// Spelling marks are noise on syntax and code. In a row whose cells wrap there are none
    /// either. MEASURED: a line that has no height of its own, as every line but the first of
    /// such a row, draws its marks 18 pt too low (16 pt text): through the text of the line
    /// below or under the row. `BlockFragment.draw` cuts off those that were set before.
    func suppressesSpelling(in range: NSRange, of text: NSString) -> Bool {
        func intersects(_ other: NSRange) -> Bool { NSIntersectionRange(other, range).length > 0 }
        let lines = lines(touching: range)
        return zip(lines, map.lines[lines]).contains { index, line in
            switch line.kind {
            case .codeFence, .codeBody, .source: return intersects(line.range)
            case .tableRow where intersects(line.range) && grid(ofTableAt: index, in: text)?.wraps == true: return true
            default: break
            }
            return line.tokens.contains { token in
                token.markerRanges.contains(where: intersects) || token.kind == .code && intersects(token.contentRange)
                    || (token.kind == .image || token.kind == .html) && intersects(token.range)
            }
        }
    }

    // MARK: display paragraphs

    func textContentStorage(_ contentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        guard let storage = contentStorage.textStorage else { return nil }
        rendered.insert(integersIn: range.location..<NSMaxRange(range))
        behind.remove(integersIn: range.location..<NSMaxRange(range))
        let paragraph = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        // Raw text is always safe. The range check costs nothing and has never been seen to fail.
        guard !isStale, let index = map.lineIndex(startingAt: range.location), map.lines[index].range == range else {
            // Where the container is wider than the column, raw text stands in the column all the same.
            guard tableRoom > columnWidth, paragraph.length > 0,
                  let style = (paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle ?? .default)
                    .mutableCopy() as? NSMutableParagraphStyle else { return nil }
            style.firstLineHeadIndent = columnOrigin
            style.headIndent = columnOrigin
            style.tailIndent = columnOrigin + columnWidth
            style.tabStops = tabStops(style.tabStops, in: paragraph)
            paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
            return NSTextParagraph(attributedString: paragraph)
        }
        style(paragraph, lineAt: index, in: storage.string as NSString)
        return NSTextParagraph(attributedString: paragraph)
    }

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        BlockFragment(textElement: textElement, range: textElement.elementRange)
    }

    private func style(_ paragraph: NSMutableAttributedString, lineAt index: Int, in text: NSString) {
        let line = map.lines[index]
        let whole = NSRange(location: 0, length: paragraph.length)
        func local(_ range: NSRange) -> NSRange {
            NSRange(location: range.location - line.range.location, length: range.length)
        }
        func kind(_ offset: Int) -> LineStyle.Kind? {
            map.lines.indices.contains(index + offset) ? map.lines[index + offset].kind : nil
        }
        let lineRevealed = lineRevealRange(index, in: text).map { touches($0, revealSelection) } ?? false
        let (indent, markerEdge, bars) = columns(ofLineAt: index)
        let textColor = line.quoteDepth > 0 ? theme.quoteText : theme.text
        let codeFont = theme.codeFont(size: theme.codeBlockFontSize)
        var isSource = false
        var panel: CodePanel?
        var wrapIndent: CGFloat = 0
        var row: TableRow?
        var stops: [NSTextTab] = []

        switch line.kind {
        case .paragraph:
            paragraph.addAttributes(block(theme.bodyFont, textColor, lineHeight: theme.bodyLineHeight), range: whole)
        case .source:
            paragraph.addAttributes(block(codeFont, theme.mutedText, lineHeight: theme.codeBlockLineHeight), range: whole)
        case .blank:
            // An empty list item still shows its marker.
            let height = line.listMarkers.isEmpty ? theme.blankLineHeight : theme.bodyLineHeight
            paragraph.addAttributes(block(theme.bodyFont, textColor, lineHeight: height), range: whole)
        case .rule:
            if lineRevealed {
                paragraph.addAttributes(block(theme.bodyFont, theme.marker, lineHeight: theme.ruleLineHeight), range: whole)
            } else {
                paragraph.addAttributes(block(theme.hiddenFont, .clear, lineHeight: theme.ruleLineHeight), range: whole)
                paragraph.addAttribute(.rule, value: theme.hairline, range: whole)
            }
        case .heading(let level):
            let font = theme.headingFont(level: level)
            let isRuled = level <= theme.ruledHeadingLevel && !line.headingMarkers.isEmpty
            paragraph.addAttributes(block(
                font, level == theme.headingSizes.count ? theme.mutedText : textColor,
                lineHeight: (font.pointSize * theme.headingLineHeightMultiple).rounded(),
                // Not above the text's first line: the text system gives the first paragraph none.
                before: theme.headingSpacingsBefore[min(max(level, 1), theme.headingSpacingsBefore.count) - 1],
                // A setext heading keeps its underline line directly below it.
                after: isRuled ? theme.underlineLineHeight : line.headingMarkers.isEmpty ? 0 : theme.headingSpacingAfter
            ), range: whole)
            if isRuled { paragraph.addAttribute(.hairline, value: theme.hairline, range: whole) }
            for marker in line.headingMarkers { setMarker(paragraph, local(marker), revealed: lineRevealed, hidden: theme.hiddenFont) }
        case .headingUnderline:
            // The same height either way, so that nothing below moves when the caret comes by.
            if lineRevealed {
                paragraph.addAttributes(block(theme.underlineFont, theme.marker, lineHeight: theme.underlineLineHeight), range: whole)
            } else {
                paragraph.addAttributes(block(theme.hiddenFont, .clear, lineHeight: theme.underlineLineHeight), range: whole)
                paragraph.addAttribute(.rule, value: theme.hairline, range: whole)
            }
        case .codeFence(_, let isClosing):
            // The fence lines are the panel's top and bottom padding.
            let endsBlock = isClosing || !isCode(kind(1), after: line.kind)
            paragraph.addAttributes(block(
                theme.codeFont(size: theme.fenceFontSize), theme.marker, lineHeight: theme.fenceLineHeight,
                before: isClosing ? 0 : theme.codePanelMargin, after: endsBlock ? theme.codePanelMargin : 0), range: whole)
            let info = NSMaxRange(line.fenceMarker ?? line.prefixRange)
            paragraph.addAttribute(
                .foregroundColor, value: theme.mutedText, range: local(NSRange(location: info, length: NSMaxRange(line.range) - info)))
            // The fence itself shows while the selection is on its line; the line is the same height either way.
            if let marker = line.fenceMarker { setMarker(paragraph, local(marker), revealed: lineRevealed, hidden: theme.hiddenFont) }
            panel = CodePanel(x: indent, top: isClosing ? nil : 0, bottom: endsBlock ? 0 : nil)
        case .codeBody:
            let startsBlock = !isCode(line.kind, after: kind(-1)), endsBlock = !isCode(kind(1), after: line.kind)
            let inset = theme.codePanelInset
            paragraph.addAttributes(block(
                codeFont, theme.text, lineHeight: theme.codeBlockLineHeight,
                before: startsBlock ? theme.codePanelMargin + inset : 0, after: endsBlock ? theme.codePanelMargin + inset : 0), range: whole)
            for token in line.codeTokens {
                paragraph.addAttribute(.foregroundColor, value: color(of: token.kind), range: local(token.range))
            }
            panel = CodePanel(x: indent, top: startsBlock ? inset : nil, bottom: endsBlock ? inset : nil)
            wrapIndent = theme.codeWrapIndent
        case .tableRow(let isHeader):
            if let shown = showGridRow(at: index, isHeader: isHeader, in: paragraph, textColor, text: text) {
                (row, stops) = shown
            } else {
                isSource = true
                panel = showTableSource(in: paragraph, textColor, pipes: line.pipes.map { local(NSRange(location: $0, length: 1)) },
                                        startsBlock: !isTable(kind(-1)), endsBlock: !isTable(kind(1)), x: indent)
                wrapIndent = theme.codeWrapIndent
            }
        case .tableDelimiter:
            if grid(ofTableAt: index, in: text) != nil {
                paragraph.addAttributes(block(theme.hiddenFont, .clear, lineHeight: theme.hiddenSize), range: whole)
            } else {
                panel = showTableSource(in: paragraph, theme.marker, pipes: [], startsBlock: false, endsBlock: !isTable(kind(1)), x: indent)
                wrapIndent = theme.codeWrapIndent
            }
        }

        let prefix = local(line.prefixRange)
        let markerWidth = showMarkers(of: line, in: paragraph)
        let padding = panel == nil ? 0 : theme.codePanelPadding
        if whole.length > 0, let base = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            // The lines of a row whose cells wrap get their indents later, cell by cell (`wrapCells`).
            let wraps = row?.cellStarts.isEmpty == false
            style.headIndent = indent + padding + wrapIndent
            style.firstLineHeadIndent = markerWidth > 0 ? max(0, markerEdge - markerWidth) : indent + padding
            // In a container wider than the column the text still ends at the column; only a grid goes on.
            style.tailIndent = row != nil ? 0 : tableRoom > columnWidth ? columnWidth - padding : -padding
            // And may start to the left of the column, with its first tab stop.
            if let row, markerWidth == 0 { style.firstLineHeadIndent = row.edges[0] }
            if markerWidth > 0, indent + padding > markerEdge, !wraps {
                // The marker hangs left of its own item's content, and a quote bar or a code panel's
                // edge comes between them: a tab carries the text over to where it starts.
                paragraph.replaceCharacters(in: NSRange(location: NSMaxRange(prefix) - 1, length: 1), with: "\t")
                stops.insert(NSTextTab(textAlignment: .left, location: indent + padding), at: 0)
            }
            // All of these are from the column's left edge so far, and a paragraph style's are from the container's.
            let origin = columnOrigin
            style.headIndent += origin
            style.firstLineHeadIndent += origin
            if style.tailIndent > 0 { style.tailIndent += origin }
            style.tabStops = tabStops(stops.isEmpty ? style.tabStops : stops, in: paragraph)
            // In a grid of single lines nothing wraps: a table too wide for that has the other kind of grid.
            if row != nil, !wraps { style.lineBreakMode = .byClipping }
            paragraph.addAttribute(.paragraphStyle, value: style, range: whole)
        }
        if let panel { paragraph.addAttribute(.codePanel, value: panel, range: whole) }
        if let row { paragraph.addAttribute(.tableRow, value: row, range: whole) }
        if !bars.isEmpty { paragraph.addAttribute(.quoteBars, value: bars, range: whole) }
        if !isSource { styleTokens(of: line, in: paragraph) }
        showIcons(in: paragraph)
        if let row, !row.cellStarts.isEmpty, let table = map.table(atLine: index) {
            wrapCells(ofRowAt: index, in: paragraph, row: row, alignments: table.alignments, markerWidth: markerWidth, text: text)
        }
    }

    private func isTable(_ kind: LineStyle.Kind?) -> Bool {
        switch kind {
        case .tableRow, .tableDelimiter: true
        default: false
        }
    }

    /// A row of a table that shows as a grid: every pipe becomes a tab. Returns the row's part of
    /// the grid and one tab stop for each pipe; nil for a table that shows as its source.
    private func showGridRow(
        at index: Int, isHeader: Bool, in paragraph: NSMutableAttributedString, _ color: NSColor, text: NSString
    ) -> (row: TableRow, stops: [NSTextTab])? {
        guard let table = map.table(atLine: index), let grid = grid(ofTableAt: index, in: text) else { return nil }
        let line = map.lines[index], whole = NSRange(location: 0, length: paragraph.length)
        func local(_ range: NSRange) -> NSRange { NSRange(location: range.location - line.range.location, length: range.length) }
        // A table without rows ends with its delimiter line.
        let isLast = index == table.lines.upperBound - 1 || table.lines.count == 2
        var row = TableRow(edges: grid.edges, isHeader: isHeader, isLast: isLast, isStriped: (index - table.lines.lowerBound) % 2 == 1)
        if grid.wraps {
            // Lines of the usual height; `wrapCells` puts each cell's into its column.
            paragraph.addAttributes(block(cellFont(of: line, isCompact: false), color, lineHeight: theme.bodyLineHeight), range: whole)
            row.cellStarts = line.cells.indices.map { $0 == 0 ? 0 : line.pipes[$0] + 1 - line.range.location }
            return (row, [])
        }
        // The line is as high as the row, so that the selection fills the row between its borders.
        paragraph.addAttributes(block(
            cellFont(of: line, isCompact: grid.isCompact), color, lineHeight: theme.bodyLineHeight + 2 * theme.tableCellPadding.height,
            before: isHeader ? theme.tableMargin : 0, after: isLast ? theme.tableMargin : 0), range: whole)
        paragraph.mutableString.replaceOccurrences(of: "\t", with: " ", range: whole)
        for pipe in line.pipes { paragraph.replaceCharacters(in: local(NSRange(location: pipe, length: 1)), with: "\t") }
        // Blanks outside the outer pipes would push the cells off their stops.
        var outside = [NSRange(location: line.range.location, length: line.pipes[0] - line.range.location)]
        if line.cells.count < line.pipes.count, let last = line.pipes.last {
            outside.append(NSRange(location: last + 1, length: NSMaxRange(line.range) - last - 1))
        }
        for range in outside { paragraph.addAttributes([.font: theme.hiddenFont, .foregroundColor: NSColor.clear], range: local(range)) }
        return (row, tabStops(grid, alignments: table.alignments))
    }

    /// The last step for a row whose cells wrap, on a paragraph that is styled otherwise (see
    /// TableWrap.swift). Every pipe between two cells becomes a line separator, and so does a
    /// "<br>" that the selection does not touch. What is hidden keeps its character's place and
    /// shows as a character without width in the cell's font, not in the hidden font: lines
    /// start with these, and each line's text is placed by where its own box ends. Each cell's
    /// lines get a paragraph style that puts them into the cell's column; no line has a height
    /// but the row's first, which is as high as the whole row.
    private func wrapCells(
        ofRowAt index: Int, in paragraph: NSMutableAttributedString, row: TableRow, alignments: [ColumnAlignment], markerWidth: CGFloat, text: NSString
    ) {
        let line = map.lines[index], whole = NSRange(location: 0, length: paragraph.length), start = line.range.location
        func local(_ range: NSRange) -> NSRange { NSRange(location: range.location - start, length: range.length) }
        let font = cellFont(of: line, isCompact: false)
        func hide(_ range: NSRange, as character: String = Self.hidden) {
            paragraph.replaceCharacters(in: local(range), with: String(repeating: character, count: range.length))
            paragraph.addAttributes([.font: font, .foregroundColor: NSColor.clear], range: local(range))
        }
        func separate(at offset: Int) { paragraph.replaceCharacters(in: local(NSRange(location: offset, length: 1)), with: "\u{2028}") }
        paragraph.mutableString.replaceOccurrences(of: "\t", with: " ", range: whole)
        // Inline markers and the line's block markers.
        var markers: [NSRange] = []
        paragraph.enumerateAttribute(.font, in: whole) { value, range, _ in
            if let font = value as? NSFont, font.pointSize < 1 { markers.append(range) }
        }
        for range in markers { hide(NSRange(location: range.location + start, length: range.length), as: Self.hiddenMarker) }
        for (column, lead) in (cellLeads(ofLineAt: index, in: text) ?? []).enumerated() {
            // Of the first cell's, the block markers are done; a list's bullet among them shows.
            let from = column == 0 ? NSMaxRange(line.prefixRange) : lead.location
            hide(NSRange(location: from, length: NSMaxRange(lead) - from))
            if column > 0 { separate(at: lead.location) }
        }
        if line.cells.count < line.pipes.count, let closing = line.pipes.last { hide(NSRange(location: closing, length: 1)) }
        for tag in lineBreaks(of: line, in: text) where !isRevealed(tag, on: line) {
            // With the blanks behind it, which would indent the line it starts.
            var end = NSMaxRange(tag.range)
            while end < NSMaxRange(line.range), text.character(at: end) == 0x20 { end += 1 }
            hide(NSRange(location: tag.range.location, length: end - tag.range.location))
            separate(at: tag.range.location)
        }

        guard let base = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle else { return }
        let padding = theme.tableCellPadding, contentEnd = text.lineContentEnd(at: start) - start
        // Each cell's lines: from behind the pipe before it up to and with the pipe behind it, which ends its last line.
        let cells = line.cells.indices.map { column in
            let first = column == 0 ? 0 : line.pipes[column] + 1 - start
            return NSRange(location: first, length: (column + 1 < line.pipes.count ? line.pipes[column + 1] + 1 - start : whole.length) - first)
        }
        let widths = cells.indices.map { row.edges[$0 + 1] - row.edges[$0] - 2 * padding.width }
        // How many lines each cell takes, as the text system will break them. Not counted in is
        // the marker of a list item, which hangs in front of the first cell's first line: that
        // line is as much longer as the marker is wide; nor the hidden closing pipe, which the
        // text system leaves on a line that is full and the typesetter gives one of its own.
        let textEnd = line.cells.count < line.pipes.count ? line.pipes[line.pipes.count - 1] - start : contentEnd
        let counts = lineCounts.object(forKey: Self.key(row, paragraph.string)) as? [Int] ?? zip(cells, widths).map { cell, width in
            guard cell.length > 0 else { return 0 }
            let first = max(cell.location, line.prefixRange.length)
            let range = NSRange(location: first, length: max(min(NSMaxRange(cell), max(textEnd, cell.location)), first) - first)
            let setter = CTTypesetterCreateWithAttributedString(paragraph.attributedSubstring(from: range))
            var from = 0, count = 0
            repeat {
                from += CTTypesetterSuggestLineBreak(setter, from, Double(width))
                count += 1
            } while from < range.length
            return count
        }
        // TextKit stacks the lines of all cells, so every line has the least height there is
        // but the row's first, which is as high as the row; the fragment draws each line where
        // it belongs. The first, and its first character in the hidden font where that is
        // hidden, because of the height TextKit guesses for a row that is not laid out.
        // MEASURED (OSCanaryTests): the line height on the paragraph's first character, times
        // the lines it expects from the paragraph's length and that character's font. With the
        // height on another line the guess was next to nothing, with the cell's font several
        // times too much, and the scroller and every far scroll went by it.
        var row = row
        row.lineCounts = counts
        paragraph.addAttribute(.tableRow, value: row, range: whole)
        let height = theme.bodyLineHeight * CGFloat(counts.max() ?? 0) + 2 * padding.height
            + (row.isHeader ? theme.tableMargin : 0) + (row.isLast ? theme.tableMargin : 0)
        for (column, cell) in cells.enumerated() where cell.length > 0 {
            let style = base.mutableCopy() as! NSMutableParagraphStyle
            style.headIndent = columnOrigin + row.edges[column] + padding.width
            // The marker of a list item that the table starts hangs in front of the grid.
            style.firstLineHeadIndent = style.headIndent - (column == 0 ? markerWidth : 0)
            style.tailIndent = columnOrigin + row.edges[column + 1] - padding.width
            if column < alignments.count { style.alignment = [.center: .center, .right: .right][alignments[column]] ?? .natural }
            style.minimumLineHeight = theme.hiddenSize
            style.maximumLineHeight = theme.hiddenSize
            paragraph.addAttribute(.paragraphStyle, value: style, range: cell)
            guard column == 0 else { continue }
            let first = style.mutableCopy() as! NSMutableParagraphStyle
            first.minimumLineHeight = height - theme.hiddenSize * CGFloat(counts.reduce(0, +) - 1)
            first.maximumLineHeight = first.minimumLineHeight
            paragraph.addAttribute(.paragraphStyle, value: first, range: NSRange(location: 0, length: 1))
            // Not a list's marker, which shows there and has its width.
            if [Self.hidden, Self.hiddenMarker].contains(paragraph.mutableString.substring(to: 1)) {
                paragraph.addAttribute(.font, value: theme.hiddenFont, range: NSRange(location: 0, length: 1))
            }
        }
    }

    /// What decides how a row's cells break: their widths, the font and the text as it shows.
    private static func key(_ row: TableRow, _ text: String) -> NSString { "\(row.isHeader)\(row.edges)\(text)" as NSString }

    /// The lines of each cell that TextKit laid a row of wrapping cells out with, where
    /// `wrapCells` had counted others: the row is rendered with these from now on. False when
    /// they are what it was rendered with, so that nothing is asked for twice.
    func correct(lineCounts counts: [Int], of row: TableRow, showing text: String) -> Bool {
        let key = Self.key(row, text)
        guard lineCounts.object(forKey: key) as? [Int] != counts else { return false }
        lineCounts.setObject(counts as NSArray, forKey: key)
        return true
    }

    /// What a hidden character shows as where cells wrap: U+2060, which has no width and, unlike
    /// U+200B, allows no line break beside it.
    private static let hidden = "\u{2060}"
    /// And a hidden inline marker: U+200C, which has no width either and leaves the breaks
    /// between the words around it as they are. U+2060 would glue "a **b**" together.
    private static let hiddenMarker = "\u{200C}"

    /// A line of a table that cannot show as a grid: its source as it is, set like a block of code,
    /// with the pipes dimmed. Returns the line's part of the panel behind the table.
    private func showTableSource(
        in paragraph: NSMutableAttributedString, _ color: NSColor, pipes: [NSRange], startsBlock: Bool, endsBlock: Bool, x: CGFloat
    ) -> CodePanel {
        let inset = theme.codePanelInset
        paragraph.addAttributes(block(
            theme.codeFont(size: theme.codeBlockFontSize), color, lineHeight: theme.codeBlockLineHeight,
            before: startsBlock ? theme.codePanelMargin + inset : 0, after: endsBlock ? theme.codePanelMargin + inset : 0),
            range: NSRange(location: 0, length: paragraph.length))
        for pipe in pipes { paragraph.addAttribute(.foregroundColor, value: theme.marker, range: pipe) }
        return CodePanel(x: x, top: startsBlock ? inset : nil, bottom: endsBlock ? inset : nil)
    }

    /// Styles the line's inline tokens in `paragraph`, which holds the line's text. Table cells are
    /// measured with this too, so that the columns are as wide as what is displayed.
    private func styleTokens(of line: LineStyle, in paragraph: NSMutableAttributedString, touched: Bool = true) {
        func local(_ range: NSRange) -> NSRange {
            NSRange(location: range.location - line.range.location, length: range.length)
        }
        /// Where the last picture's source ends; what is nested in it is hidden or shown with it.
        var pictureEnd = 0
        for token in line.tokens where token.range.location >= pictureEnd {
            let revealed = isRevealed(token, on: line, touched: touched)
            if showsPicture(token, on: line) {
                showPicture(of: token, on: line, in: paragraph, revealed: revealed)
                pictureEnd = NSMaxRange(token.range)
                continue
            }
            style(token, in: paragraph, revealed: revealed, local: local)
            // The hidden backticks of inline code are the padding of its background.
            let hidden = token.kind == .code ? theme.inlineCodeEdgeFont : theme.hiddenFont
            for marker in token.markerRanges { setMarker(paragraph, local(marker), revealed: revealed, hidden: hidden) }
        }
    }

    /// The size an image shows at where the column leaves it `room`: its own, or scaled down to fit.
    private func shownSize(of image: ImageCache.Picture, room: CGFloat?) -> CGSize {
        let size = CGSize(width: image.size.width * Theme.zoom, height: image.size.height * Theme.zoom)
        let fit = room.map { min(1, $0 / max(size.width, 1)) } ?? 1
        return CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
    }

    /// Puts the picture where the image's "!" is, with the rest of its source hidden like any marker.
    /// An image alone on its line stands above its source, which is laid out under it whether it
    /// shows or not: then nothing moves when the selection comes by and reveals it.
    private func showPicture(of token: InlineToken, on line: LineStyle, in paragraph: NSMutableAttributedString, revealed: Bool) {
        let source = NSRange(location: token.range.location - line.range.location, length: token.range.length)
        let mark = NSRange(location: source.location, length: 1), rest = NSRange(location: source.location + 1, length: source.length - 1)
        let text = paragraph.string as NSString
        let around = text.substring(with: NSRange(location: line.prefixRange.length, length: source.location - line.prefixRange.length))
            + text.substring(from: NSMaxRange(source))
        let isAlone = line.kind == .paragraph && around.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        // Before the view has its size the column has no width yet.
        let room = columnWidth == .greatestFiniteMagnitude ? nil : (columnWidth + columnOrigin - (style?.headIndent ?? 0)).rounded(.down)

        var picture: ShownImage
        let entry = images.entry(for: token.destination ?? "")
        if case .image(let image) = entry {
            picture = ShownImage(image: image, size: shownSize(of: image, room: room))
        } else {
            let alt = text.substring(with: NSRange(location: token.contentRange.location - line.range.location, length: token.contentRange.length))
            let side = theme.inlineImagePlaceholderSize
            var size = isAlone ? theme.imagePlaceholderSize : CGSize(width: side, height: side)
            if let room { size.width = min(size.width, room) }
            picture = ShownImage(image: nil, label: alt.isEmpty ? ((token.destination ?? "") as NSString).lastPathComponent : alt, size: size)
            if case .missing = entry { picture.isMissing = true }
            if case .blocked(let source) = entry {
                picture.isBlocked = true
                picture.label = "Remote image blocked\n\(source)"
            }
        }

        guard let style = style?.mutableCopy() as? NSMutableParagraphStyle else { return }
        if isAlone, line.range.location > 0 {
            // The picture stands in the room above the line, which is the line of its source: a
            // line as high as the picture would have a caret as high in front of it.
            picture.isAboveLine = true
            paragraph.addAttributes([.font: theme.captionFont, .foregroundColor: revealed ? theme.marker : NSColor.clear], range: source)
            paragraph.addAttribute(.picture, value: picture, range: mark)
            style.minimumLineHeight = theme.imageCaptionLineHeight
            style.maximumLineHeight = theme.imageCaptionLineHeight
            style.paragraphSpacingBefore = theme.imageSpacingBefore + picture.size.height
        } else {
            // A picture no higher than a line of text is centred on the capitals, like a checkbox.
            let font = theme.bodyFont
            if picture.size.height <= theme.bodyLineHeight {
                picture.drop = -max(((font.capHeight - picture.size.height) / 2).rounded(), font.descender.rounded(.up))
            }
            let attachment = NSTextAttachment()
            attachment.image = Self.nothing
            // The text's first paragraph gets no spacing before it. An image alone on that line is
            // an attachment as wide as the line instead, which puts its source on a line below it.
            attachment.bounds = CGRect(x: 0, y: -picture.drop, width: isAlone ? room ?? picture.size.width : picture.size.width,
                                       height: picture.size.height)
            paragraph.replaceCharacters(in: mark, with: "\u{FFFC}")
            paragraph.addAttributes([.attachment: attachment, .picture: picture], range: mark)
            paragraph.addAttributes([
                .font: isAlone ? theme.captionFont : revealed ? theme.bodyFont : theme.hiddenFont,
                .foregroundColor: revealed ? theme.marker : NSColor.clear,
            ], range: rest)
            // The line is as high as its picture.
            style.maximumLineHeight = 0
            if isAlone { style.minimumLineHeight = theme.imageCaptionLineHeight }
        }
        paragraph.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: paragraph.length))
    }

    /// The attachment of an image in a line of text draws nothing itself: BlockFragment draws the picture in the room it makes.
    private static let nothing = NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }

    /// Whether a line of kind `kind` is part of the code block that the line of kind `previous` before it is in.
    private func isCode(_ kind: LineStyle.Kind?, after previous: LineStyle.Kind?) -> Bool {
        switch (previous, kind) {
        case (.codeBody, .codeBody), (.codeBody, .codeFence(_, isClosing: true)),
             (.codeFence(_, isClosing: false), .codeBody), (.codeFence(_, isClosing: false), .codeFence(_, isClosing: true)):
            true
        default:
            false
        }
    }

    private func color(of kind: CodeToken.Kind) -> NSColor {
        switch kind {
        case .comment: theme.codeComment
        case .string: theme.codeString
        case .number: theme.codeNumber
        case .keyword: theme.codeKeyword
        }
    }

    /// Where the line's content starts in the column, where the content of its innermost list item
    /// starts, and the bars of the quotes it is in. Each enclosing quote and list item moves the
    /// content right by its own step.
    private func columns(ofLineAt index: Int) -> (indent: CGFloat, markerEdge: CGFloat, bars: [QuoteBar]) {
        let containers = map.lines[index].containers
        func isInSameQuote(_ other: Int, depth: Int) -> Bool {
            map.lines.indices.contains(other) && map.lines[other].containers.prefix(depth + 1) == containers.prefix(depth + 1)
        }
        var x: CGFloat = 0, markerEdge: CGFloat = 0
        var bars: [QuoteBar] = []
        for (depth, container) in containers.enumerated() {
            switch container {
            case .quote:
                bars.append(QuoteBar(
                    x: x, isFirst: !isInSameQuote(index - 1, depth: depth), isLast: !isInSameQuote(index + 1, depth: depth)))
                x += theme.quoteIndent
            case .listItem(let markerLength):
                x += listIndent(markerLength: markerLength)
                markerEdge = x
            }
        }
        return (x, markerEdge, bars)
    }

    /// How far a list level moves its content right: the theme's indent, or more where the numbers
    /// of an ordered list need it. All items of a list get the same, so their text lines up.
    private func listIndent(markerLength: Int) -> CGFloat {
        // "9." fits the theme's indent.
        guard markerLength > 2 else { return theme.listIndent }
        let widest = NSMutableAttributedString(
            string: String(repeating: "0", count: markerLength - 1) + ".", attributes: [.font: theme.orderedMarkerFont])
        widest.append(NSAttributedString(string: " ", attributes: [.font: theme.bodyFont]))
        return max(theme.listIndent, widest.size().width.rounded(.up))
    }

    /// Hides the line's block markers and puts in their place what stands for them: a bullet glyph,
    /// the number as typed, or a checkbox, each followed by one space. Returns the width of what shows.
    private func showMarkers(of line: LineStyle, in paragraph: NSMutableAttributedString) -> CGFloat {
        let prefix = NSRange(location: 0, length: line.prefixRange.length)
        guard prefix.length > 0 else { return 0 }
        paragraph.addAttributes([.font: theme.hiddenFont, .foregroundColor: NSColor.clear], range: prefix)
        var depth = line.listDepth - line.listMarkers.count
        // The room of the blank behind a marker that has none yet.
        var missingGap: CGFloat = 0
        for marker in line.listMarkers {
            depth += 1
            var shown = NSRange(location: marker.range.location - line.range.location, length: marker.range.length)
            if let box = marker.checkbox {
                shown = NSRange(location: box.range.location - line.range.location, length: 1)
                paragraph.replaceCharacters(in: shown, with: "\u{FFFC}")
                paragraph.addAttributes([.attachment: checkbox(isChecked: box.isChecked), .font: theme.bodyFont], range: shown)
                shown.length = box.range.length
            } else if marker.isOrdered {
                paragraph.addAttributes([.font: theme.orderedMarkerFont, .foregroundColor: theme.listMarker], range: shown)
            } else {
                let level = min(max(depth, 1), theme.bullets.count)
                paragraph.replaceCharacters(in: shown, with: theme.bullets[level - 1])
                paragraph.addAttributes([.font: theme.bodyFont, .foregroundColor: NSColor.clear, .bullet: level], range: shown)
            }
            let gap = NSRange(location: NSMaxRange(shown), length: 1), blank = marker.isOrdered || marker.checkbox != nil ? " " : theme.bulletGap
            if gap.location < prefix.length {
                paragraph.replaceCharacters(in: gap, with: blank)
                paragraph.addAttribute(.font, value: theme.bodyFont, range: gap)
            } else {
                // A marker that is typed without its blank yet stands where it will stand with
                // it, in line with the other items' markers: the blank moves the caret, not the marker.
                missingGap = NSAttributedString(string: blank, attributes: [.font: theme.bodyFont]).size().width
            }
        }
        return line.listMarkers.isEmpty ? 0 : paragraph.attributedSubstring(from: prefix).size().width + missingGap
    }

    /// Unchecked and checked, made when first needed at the current zoom.
    private var checkboxImages: [NSImage?] = []

    private func checkbox(isChecked: Bool) -> NSTextAttachment {
        if checkboxImages.isEmpty {
            checkboxImages = [false, true].map { isChecked in
                let colors = isChecked ? [theme.checkmark, theme.accent] : [theme.uncheckedBox]
                let configuration = NSImage.SymbolConfiguration(pointSize: theme.checkboxSize, weight: theme.checkboxWeight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: colors))
                let names = theme.checkboxSymbols
                return NSImage(systemSymbolName: isChecked ? names.checked : names.unchecked, accessibilityDescription: nil)?
                    .withSymbolConfiguration(configuration)
            }
        }
        let attachment = NSTextAttachment()
        let image = checkboxImages[isChecked ? 1 : 0]
        let size = image?.size ?? .zero
        attachment.image = image
        // Centred on the capitals, but never below the font's descent: that would make the line higher.
        let font = theme.bodyFont
        attachment.bounds = CGRect(origin: CGPoint(x: 0, y: max(((font.capHeight - size.height) / 2).rounded(), font.descender.rounded(.up))), size: size)
        return attachment
    }

    private func style(
        _ token: InlineToken, in paragraph: NSMutableAttributedString, revealed: Bool, local: (NSRange) -> NSRange
    ) {
        let content = local(token.contentRange)
        switch token.kind {
        case .strong:
            addTrait(.bold, to: paragraph, in: content)
        case .emphasis:
            addTrait(.italic, to: paragraph, in: content)
        case .strikethrough:
            paragraph.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: theme.mutedText], range: content)
        case .link:
            paragraph.addAttribute(.foregroundColor, value: theme.link, range: content)
            if revealed || token.range == hoveredLink {
                paragraph.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: content)
            }
        case .code:
            let piece = token.markerRanges.reduce(content) { NSUnionRange($0, local($1)) }
            guard piece.length > 0 else { return }
            let size = (paragraph.attribute(.font, at: piece.location, effectiveRange: nil) as? NSFont)?.pointSize ?? theme.bodyFont.pointSize
            paragraph.addAttributes(
                [.font: theme.codeFont(size: size * theme.inlineCodeScale), .inlineBackground: theme.codeBackground], range: piece)
        case .html:
            paragraph.addAttribute(.foregroundColor, value: theme.marker, range: content)
        case .image, .escape:
            break
        }
    }

    /// Sets the characters that only an icon font draws (the icons of a terminal prompt) in an
    /// installed one, where there is one. A paragraph without such a character costs one search.
    private func showIcons(in paragraph: NSMutableAttributedString) {
        let text = paragraph.mutableString
        var rest = NSRange(location: 0, length: text.length)
        while case let found = text.rangeOfCharacter(from: IconFont.characters, range: rest), found.location != NSNotFound {
            if let font = paragraph.attribute(.font, at: found.location, effectiveRange: nil) as? NSFont,
               let icons = IconFont.font(for: text.substring(with: found), inPlaceOf: font) {
                paragraph.addAttribute(.font, value: icons, range: found)
            }
            rest = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
    }

    private func setMarker(_ paragraph: NSMutableAttributedString, _ range: NSRange, revealed: Bool, hidden: NSFont) {
        if revealed {
            paragraph.addAttribute(.foregroundColor, value: theme.marker, range: range)
        } else {
            paragraph.addAttributes([.font: hidden, .foregroundColor: NSColor.clear], range: range)
        }
    }

    private func addTrait(_ trait: NSFontDescriptor.SymbolicTraits, to paragraph: NSMutableAttributedString, in range: NSRange) {
        paragraph.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? NSFont else { return }
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
            paragraph.addAttribute(.font, value: NSFont(descriptor: descriptor, size: font.pointSize) ?? font, range: run)
        }
    }

    /// Block-level attributes: a fixed line height, so mixed fonts, hidden markers and fallback glyphs
    /// never change it. TextKit puts the spare height above the glyphs; BlockFragment lifts them to the middle.
    private func block(
        _ font: NSFont, _ color: NSColor, lineHeight: CGFloat, before: CGFloat = 0, after: CGFloat = 0
    ) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return [.font: font, .foregroundColor: color, .paragraphStyle: style, .glyphLift: theme.glyphLift(of: font, lineHeight: lineHeight)]
    }
}
