import Foundation

/// Finds where the block markers at the start of a line end, given the containers the parser says
/// the line is in. The parser's own container ranges are not used for this: ListItem ends are loose.
struct BlockPrefixScanner {
    enum Container: Equatable {
        case quote
        case listItem(Int)
    }

    struct Item {
        /// 0-based line holding the marker.
        var line: Int
        var isOrdered: Bool
        /// Columns from the item's start to its content, learnt on the marker line.
        var indent = 2
    }

    struct Prefix {
        var end: Int
        var markers: [ListMarker] = []
        /// A container's marker or indentation is missing, so the line continues a paragraph lazily.
        var isLazy = false
        /// Columns of a tab at the end of the prefix that the containers did not use up. cmark hands
        /// them to a lazy line's text as spaces.
        var padding = 0
    }

    /// A position with its column. cmark measures indentation in columns, where a tab runs to the
    /// next multiple of four and can be consumed in part.
    private struct Cursor {
        var i: Int
        var column = 0
        /// The first columns of the tab at `i` are consumed.
        var inTab = false

        /// Consumes up to `limit` columns of spaces and tabs and returns how many.
        mutating func skipBlanks(_ units: [UInt16], to end: Int, limit: Int) -> Int {
            var taken = 0
            while taken < limit, i < end, units[i] == 0x20 || units[i] == 0x09 {
                let width = units[i] == 0x20 ? 1 : 4 - column % 4
                let step = min(width, limit - taken)
                column += step
                taken += step
                inTab = step < width
                if !inTab { i += 1 }
            }
            return taken
        }

        mutating func advance(_ count: Int = 1) {
            i += count
            column += count
        }
    }

    var items: [Item] = []

    /// Scans `units[start..<end]`, one line without its terminator, stopping at the first container
    /// that does not match.
    mutating func scan(_ units: [UInt16], from start: Int, to end: Int, line: Int, chain: [Container]) -> Prefix {
        func isBlank(_ i: Int) -> Bool { units[i] == 0x20 || units[i] == 0x09 }
        var prefix = Prefix(end: start)
        var position = Cursor(i: start)
        scan: for container in chain {
            var c = position
            switch container {
            case .quote:
                _ = c.skipBlanks(units, to: end, limit: 3)
                guard c.i < end, units[c.i] == 0x3E else {
                    prefix.isLazy = true
                    break scan
                }
                c.advance()
                _ = c.skipBlanks(units, to: end, limit: 1)

            case .listItem(let id) where items[id].line == line:
                let offset = c.skipBlanks(units, to: end, limit: 3)
                let markerStart = c.i
                if items[id].isOrdered {
                    while c.i < end, c.i - markerStart < 9, units[c.i] >= 0x30, units[c.i] <= 0x39 { c.advance() }
                    guard c.i > markerStart, c.i < end, units[c.i] == 0x2E || units[c.i] == 0x29 else { break scan }
                } else {
                    guard c.i < end, units[c.i] == 0x2D || units[c.i] == 0x2B || units[c.i] == 0x2A else { break scan }
                }
                c.advance()
                let markerEnd = c
                var spaces = c.skipBlanks(units, to: end, limit: 5)
                if spaces == 0, c.i < end { break scan }
                if spaces == 5 || c.i == end {
                    // An empty item, or content that is indented code: both start one column after the marker.
                    c = markerEnd
                    _ = c.skipBlanks(units, to: end, limit: 1)
                    spaces = 1
                }
                items[id].indent = offset + markerEnd.i - markerStart + spaces
                var marker = ListMarker(range: NSRange(location: markerStart, length: markerEnd.i - markerStart),
                                        isOrdered: items[id].isOrdered)
                // Read from the source: cmark-gfm misses a task item that is inside a quote or another item's line.
                if c.i + 3 < end, units[c.i] == 0x5B, [0x20, 0x78, 0x58].contains(units[c.i + 1]), units[c.i + 2] == 0x5D,
                   isBlank(c.i + 3) {
                    marker.checkbox = .init(range: NSRange(location: c.i, length: 3), isChecked: units[c.i + 1] != 0x20)
                    c.advance(3)
                    _ = c.skipBlanks(units, to: end, limit: 1)
                }
                prefix.markers.append(marker)

            case .listItem(let id):
                guard c.skipBlanks(units, to: end, limit: items[id].indent) == items[id].indent
                        || (c.i..<end).allSatisfy(isBlank) else {
                    prefix.isLazy = true
                    break scan
                }
            }
            position = c
        }
        prefix.end = position.i + (position.inTab ? 1 : 0)
        prefix.padding = position.inTab ? 4 - position.column % 4 : 0
        return prefix
    }
}
