import Foundation

public enum ColumnAlignment: Equatable, Sendable {
    case none, left, center, right
}

/// The part of one inline construct that lies on one line.
public struct InlineToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case strong, emphasis, strikethrough, code, link, image
        /// An inline HTML tag, which shows as it is written.
        case html
        /// A backslash with the punctuation character it escapes: the backslash is the marker.
        case escape
    }

    public var kind: Kind
    /// The whole construct, which may span several lines. Reveal logic tests the selection against this.
    public var range: NSRange
    /// Syntax characters on this line (hidden unless revealed).
    public var markerRanges: [NSRange]
    /// Styled text on this line. For an image this is the alt text.
    public var contentRange: NSRange
    /// Resolved destination of a link or image (reference links included), as the parser reports it.
    public var destination: String?
}

public struct ListMarker: Equatable, Sendable {
    public struct Checkbox: Equatable, Sendable {
        /// The three characters "[ ]" or "[x]".
        public var range: NSRange
        public var isChecked: Bool
    }

    /// The bullet character, or the digits with their delimiter.
    public var range: NSRange
    public var isOrdered: Bool
    public var checkbox: Checkbox?
}

public struct TableCell: Equatable, Sendable {
    /// Everything between two pipes.
    public var range: NSRange
    /// `range` without surrounding whitespace.
    public var contentRange: NSRange
}

public struct LineStyle: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paragraph
        case heading(level: Int)
        /// The "===" or "---" line of a setext heading.
        case headingUnderline(level: Int)
        /// Only an opening fence can carry a language.
        case codeFence(language: String?, isClosing: Bool)
        case codeBody(language: String?)
        case tableRow(isHeader: Bool)
        /// Carries the alignments so that changing one changes this line.
        case tableDelimiter(alignments: [ColumnAlignment])
        case rule
        case blank
        /// Text that shows as it is written: an HTML block, front matter, a link reference definition.
        case source
    }

    public enum Container: Equatable, Sendable {
        case quote
        /// `markerLength` is that of the longest marker in the item's list as the parser numbers it,
        /// so that every item of a list can be given the same indent.
        case listItem(markerLength: Int)
    }

    /// The line including its terminator.
    public var range: NSRange
    public var kind: Kind = .paragraph
    /// Enclosing quotes and list items, outermost first. Set on lazy continuation lines too.
    public var containers: [Container] = []
    /// Whether the line may start a link reference definition; see `StyleMap.hasReferences`.
    public var mayDefineReference = false
    /// Indentation, quote markers, list markers and checkboxes at the start of the line.
    public var prefixRange: NSRange
    /// List items that start on this line, outermost first. Their ranges lie inside `prefixRange`.
    public var listMarkers: [ListMarker] = []
    /// The opening "## " and optional closing " ##" of an ATX heading.
    public var headingMarkers: [NSRange] = []
    /// The run of backticks or tildes on a line of a fenced code block that reads as a fence: the
    /// opening and closing lines, and a body line that would open or close a block elsewhere.
    public var fenceMarker: NSRange?
    public var cells: [TableCell] = []
    /// Offsets of the unescaped pipes of a table row or delimiter line, the leading one included.
    public var pipes: [Int] = []
    public var tokens: [InlineToken] = []
    /// Syntax colouring of a code body line whose language the tokenizer knows.
    public var codeTokens: [CodeToken] = []

    public init(range: NSRange) {
        self.range = range
        prefixRange = NSRange(location: range.location, length: 0)
    }

    public var quoteDepth: Int { containers.count { $0 == .quote } }
    public var listDepth: Int { containers.count { $0 != .quote } }

    func shifted(by delta: Int) -> LineStyle {
        var line = self
        line.shift(by: delta)
        return line
    }

    /// Moves every offset of the line. In place, so that a map that is not shared is not copied.
    mutating func shift(by delta: Int) {
        guard delta != 0 else { return }
        range.location += delta
        prefixRange.location += delta
        fenceMarker?.location += delta
        for i in headingMarkers.indices { headingMarkers[i].location += delta }
        for i in pipes.indices { pipes[i] += delta }
        for i in listMarkers.indices {
            listMarkers[i].range.location += delta
            listMarkers[i].checkbox?.range.location += delta
        }
        for i in cells.indices {
            cells[i].range.location += delta
            cells[i].contentRange.location += delta
        }
        for i in tokens.indices {
            tokens[i].range.location += delta
            tokens[i].contentRange.location += delta
            for j in tokens[i].markerRanges.indices { tokens[i].markerRanges[j].location += delta }
        }
        for i in codeTokens.indices { codeTokens[i].range.location += delta }
    }
}

public struct TableStyle: Equatable, Sendable {
    /// Header, delimiter and body lines.
    public var lines: Range<Int>
    /// One entry per column; the same as on the delimiter line.
    public var alignments: [ColumnAlignment]
}

/// Lines of the old and the new map that differ. Everything outside is identical apart from its offset.
public struct LineDiff: Equatable, Sendable {
    public var old: Range<Int>
    public var new: Range<Int>
    /// The lines of the new map that differ themselves. `old` and `new` are wider where these are
    /// in or beside a table, whose rows share their columns.
    public var changed: Range<Int>

    public init(old: Range<Int>, new: Range<Int>, changed: Range<Int>? = nil) {
        self.old = old
        self.new = new
        self.changed = changed ?? new
    }
}

public struct StyleMap: Equatable, Sendable {
    public var lines: [LineStyle] = []
    /// In line order.
    public var tables: [TableStyle] = []
    /// Whether a line may be a link reference definition (`LineStyle.mayDefineReference`). One
    /// gives a meaning to brackets anywhere in the text, so a part of the text can only be parsed
    /// by itself when it has no bracket that could refer to one (`MarkdownStyler.restyle`).
    public var hasReferences = false

    public init() {}

    public func table(atLine line: Int) -> TableStyle? {
        var low = 0, high = tables.count
        while low < high {
            let mid = (low + high) / 2
            if tables[mid].lines.upperBound <= line { low = mid + 1 } else { high = mid }
        }
        return low < tables.count && tables[low].lines.contains(line) ? tables[low] : nil
    }

    /// Whether the table can be shown and edited as a grid: every line has its leading pipe and no
    /// more cells than there are columns, the delimiter line has both outer pipes, and all lines are
    /// in the same containers. Any other table is left as the source text it is.
    public func isRegular(_ table: TableStyle) -> Bool {
        let columns = table.alignments.count, header = table.lines.lowerBound
        return table.lines.allSatisfy { index in
            let line = lines[index]
            guard line.containers == lines[header].containers, let first = line.pipes.first else { return false }
            if index == header + 1 { return line.pipes.count == columns + 1 }
            return line.cells.count <= columns && line.cells.allSatisfy { $0.range.location > first }
        }
    }

    public func lineIndex(startingAt location: Int) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].range.location < location { low = mid + 1 } else { high = mid }
        }
        return low < lines.count && lines[low].range.location == location ? low : nil
    }

    /// Index of the line that holds `location`; an offset on the border of two lines belongs to the later one.
    public func lineIndex(containing location: Int) -> Int? {
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].range.location <= location { low = mid + 1 } else { high = mid }
        }
        return low > 0 && location <= NSMaxRange(lines[low - 1].range) ? low - 1 : nil
    }

    /// Trims the common prefix and suffix of the two line arrays; suffix lines are compared after
    /// shifting by the length change. A span that touches or borders a table grows to the whole table,
    /// because column geometry is shared by its rows and a deleted row leaves no line of its own.
    public func diff(from old: StyleMap) -> LineDiff {
        let a = old.lines, b = lines
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        let delta = (b.last.map { NSMaxRange($0.range) } ?? 0) - (a.last.map { NSMaxRange($0.range) } ?? 0)
        var tail = 0
        while tail < a.count - head, tail < b.count - head,
              a[a.count - 1 - tail].shifted(by: delta) == b[b.count - 1 - tail] { tail += 1 }
        var diff = LineDiff(old: head..<a.count - tail, new: head..<b.count - tail)
        diff.old = old.growingToTables(diff.old)
        diff.new = growingToTables(diff.new)
        return diff
    }

    func growingToTables(_ span: Range<Int>) -> Range<Int> {
        let first = table(atLine: span.lowerBound - 1) ?? table(atLine: span.lowerBound)
        let last = table(atLine: span.upperBound) ?? table(atLine: span.upperBound - 1)
        return (first?.lines.lowerBound ?? span.lowerBound)..<(last?.lines.upperBound ?? span.upperBound)
    }

    /// The heading line that a "#anchor" link points at. A heading's anchor is its text in lower
    /// case with blanks as hyphens and without punctuation, as on GitHub; a repeated one gets "-1", "-2".
    public func headingLine(forAnchor anchor: String, in text: String) -> Int? {
        let source = text as NSString, wanted = (anchor.removingPercentEncoding ?? anchor).lowercased()
        var seen: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard case .heading = line.kind, NSMaxRange(line.range) <= source.length else { continue }
            let title = NSMutableString(string: source.substring(with: line.range))
            let syntax = [line.prefixRange] + line.headingMarkers + line.tokens.flatMap(\.markerRanges)
            for range in syntax.sorted(by: { $0.location > $1.location }) where NSMaxRange(range) <= NSMaxRange(line.range) {
                title.deleteCharacters(in: NSRange(location: range.location - line.range.location, length: range.length))
            }
            let slug = String((title as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased().compactMap { character -> Character? in
                character == " " ? "-" : character.isLetter || character.isNumber || character == "-" || character == "_" ? character : nil
            })
            let count = seen[slug, default: 0]
            seen[slug] = count + 1
            if (count == 0 ? slug : "\(slug)-\(count)") == wanted { return index }
        }
        return nil
    }
}
