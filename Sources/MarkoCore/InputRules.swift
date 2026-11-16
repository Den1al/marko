import Foundation

/// Replaces `range` with `replacement` and leaves `selection`.
public struct TextEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

/// One replacement among several made together.
struct Change {
    var range: NSRange
    var text: String
    /// Whether a selection end standing where an insertion goes in ends up behind it.
    var pushes = true
}

extension TextEdit {
    /// Replaces the union of `changes`, which are in order and apart, in `text` and carries `selection` along.
    static func combining(_ changes: [Change], in text: NSString, selection: NSRange) -> TextEdit? {
        guard let first = changes.first, let last = changes.last else { return nil }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var result = "", position = range.location
        for change in changes {
            result += text.substring(with: NSRange(location: position, length: change.range.location - position)) + change.text
            position = NSMaxRange(change.range)
        }
        func moved(_ point: Int) -> Int {
            var shift = 0
            for change in changes {
                let length = (change.text as NSString).length
                if point >= NSMaxRange(change.range), point > change.range.location || change.pushes {
                    shift += length - change.range.length
                } else if point > change.range.location {
                    return change.range.location + shift + length
                } else {
                    break
                }
            }
            return point + shift
        }
        let start = moved(selection.location), end = max(start, moved(NSMaxRange(selection)))
        return TextEdit(range: range, replacement: result, selection: NSRange(location: start, length: end - start))
    }
}

public extension NSString {
    /// Where the line that holds `location` ends, its terminator not counted.
    func lineContentEnd(at location: Int) -> Int {
        var end = 0
        getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: location, length: 0))
        return end
    }
}

extension String {
    /// Block markers as a blank line carries them: without the blanks at their end.
    var trimmingTrailingBlanks: String {
        String(self[..<(lastIndex { $0 != " " && $0 != "\t" }.map { index(after: $0) } ?? startIndex)])
    }
}

/// What Return, Tab, Shift-Tab, Backspace and Delete do in lists, quotes and code; `TableEdits` has
/// what they do in tables. Each rule is a pure
/// function of the text, its style map and the selection; nil means the key keeps its usual meaning.
public enum InputRules {
    /// Several lines pasted into a line of code that stands in a list item or a quote, or is
    /// indented code: every line after the first gets what keeps it in that block, as Return
    /// gives it. The pasted lines themselves are as they were. Nil where a paste needs nothing.
    public static func paste(_ pasted: String, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let line = Line(text, map, at: selection.location), case .codeBody = line.style.kind, line.style.prefixRange.length > 0,
              selection.location >= line.contentStart, (pasted as NSString).range(of: "\n", options: .literal).location != NSNotFound else { return nil }
        let lines = (pasted as NSString).replacingOccurrences(of: "\n", with: "\n" + line.continuation(startsItem: false), options: .literal,
                                                              range: NSRange(location: 0, length: (pasted as NSString).length))
        return TextEdit(range: selection, replacement: lines, selection: NSRange(location: selection.location + (lines as NSString).length, length: 0))
    }

    /// Return: continues the list item or quote, leaves it from an empty line, closes a fence just
    /// opened (and types over that fence where the user typed one too), completes a table whose
    /// header row was just typed, or starts the next line of code as deep as this one, and one
    /// level deeper behind a line that opens a block.
    public static func newline(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let line = Line(text, map, at: selection.location),
              (line.contentStart...line.contentEnd).contains(selection.location) else { return nil }
        if let edit = line.closingFence(at: selection) ?? line.typedOverFence(at: selection) ?? line.tableStart(at: selection) { return edit }
        if selection.length == 0, let end = line.loneMarkerEnd, selection.location >= end { return line.shifted(deeper: false, selection: selection) }
        let hasPrefix = line.style.prefixRange.length > 0, indentation = line.codeIndentation(before: selection.location)
        // Without block markers or indentation the key's own Return does the same, except that it always inserts "\n".
        guard hasPrefix || line.newline != "\n" || !indentation.isEmpty else { return nil }
        if hasPrefix, selection.length == 0, !line.isCode, line.isBlank(line.contentStart..<line.contentEnd) {
            return line.unwrapped(wholeItem: true)
        }
        let insertion = line.newline + line.continuation(startsItem: !line.isCode) + indentation
        return TextEdit(range: selection, replacement: insertion,
                        selection: NSRange(location: selection.location + (insertion as NSString).length, length: 0))
    }

    /// Backspace at the start of a line's content: joins a paragraph's lines, or removes the innermost
    /// block marker. Among the blanks a line of code starts with: takes one level of indentation.
    public static func deleteBackward(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = Line(text, map, at: selection.location) else { return nil }
        if let edit = line.codeUnindented(at: selection.location) { return edit }
        if let end = line.loneMarkerEnd, selection.location > end { return line.shifted(deeper: false, selection: selection) }
        guard line.style.prefixRange.length > 0, selection.location == line.contentStart else { return nil }
        if line.style.kind == .paragraph, line.style.listMarkers.isEmpty, let previous = line.previous,
           previous.kind == .paragraph, previous.containers == line.style.containers {
            let previousEnd = line.text.lineContentEnd(at: line.start - 1)
            return TextEdit(range: NSRange(location: previousEnd, length: line.contentStart - previousEnd), replacement: "",
                            selection: NSRange(location: previousEnd, length: 0))
        }
        return line.unwrapped(wholeItem: false)
    }

    /// Forward Delete at the end of a line's content: takes the next line's block markers with the
    /// line break, so that the two contents join.
    public static func deleteForward(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length == 0, let line = Line(text, map, at: selection.location),
              selection.location == line.contentEnd, line.contentEnd > line.start, let next = line.next,
              next.prefixRange.length > 0 else { return nil }
        return TextEdit(range: NSRange(location: selection.location, length: NSMaxRange(next.prefixRange) - selection.location),
                        replacement: "", selection: selection)
    }

    /// Tab: in a code block one more level of indentation, at the caret or for every line of code
    /// that a selection from there, or from text outside any list, reaches; in a list it nests the items of the selection under the item before each. Where
    /// a list item has nothing to go under, the key does nothing.
    public static func indent(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let line = Line(text, map, at: selection.location) else { return nil }
        if let edit = line.codeIndented(deeper: true, selection: selection) ?? line.shifted(deeper: true, selection: selection) { return edit }
        return line.style.listDepth > 0 ? TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection) : nil
    }

    /// Shift-Tab: in a code block one level of indentation less for every line of the selection;
    /// in a list it moves the items of the selection out to their parents' level. An empty item
    /// that has no parent leaves the list, as it does on Return.
    public static func outdent(in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let line = Line(text, map, at: selection.location) else { return nil }
        if let edit = line.codeIndented(deeper: false, selection: selection) ?? line.shifted(deeper: false, selection: selection) { return edit }
        return selection.length == 0 && line.startsEmptyItem ? line.unwrapped(wholeItem: true) : nil
    }

    /// A closing bracket typed on a line of code that holds nothing but blanks stands one level
    /// of indentation further left.
    public static func closingBracket(_ typed: String, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard [")", "]", "}"].contains(typed), selection.length == 0, let line = Line(text, map, at: selection.location),
              line.isBlank(selection.location..<line.contentEnd), let edit = line.codeUnindented(at: selection.location) else { return nil }
        return TextEdit(range: edit.range, replacement: typed, selection: NSRange(location: edit.selection.location + 1, length: 0))
    }
}

/// The line holding the selection start, checked against the text: a map older than the text gives no line.
struct Line {
    let text: NSString
    let map: StyleMap
    let index: Int
    let style: LineStyle
    /// Without the terminator.
    let contentEnd: Int
    /// The line break to insert: this line's own, or that of the line above when it has none.
    let newline: String

    init?(_ source: String, _ map: StyleMap, at location: Int) {
        let text = source as NSString
        // A map of the same length as the text has every range inside the text, whatever else is stale.
        guard location <= text.length, map.lines.last.map({ NSMaxRange($0.range) }) == text.length,
              let index = map.lineIndex(containing: location) else { return nil }
        var start = 0, end = 0, contentEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentEnd, for: NSRange(location: location, length: 0))
        guard map.lines[index].range == NSRange(location: start, length: end - start) else { return nil }
        var breakStart = contentEnd
        if end == contentEnd, start > 0 {
            end = start
            breakStart = text.lineContentEnd(at: start - 1)
        }
        newline = end > breakStart ? text.substring(with: NSRange(location: breakStart, length: end - breakStart)) : "\n"
        self.text = text
        self.map = map
        self.index = index
        self.contentEnd = contentEnd
        style = map.lines[index]
    }

    var start: Int { style.range.location }
    var contentStart: Int { NSMaxRange(style.prefixRange) }
    var prefix: NSString { text.substring(with: style.prefixRange) as NSString }
    var previous: LineStyle? { index > 0 ? map.lines[index - 1] : nil }
    var next: LineStyle? { index + 1 < map.lines.count ? map.lines[index + 1] : nil }

    var isCode: Bool {
        switch style.kind {
        case .codeFence, .codeBody: true
        default: false
        }
    }

    func isBlank(_ range: Range<Int>) -> Bool {
        range.allSatisfy { text.character(at: $0) == 0x20 || text.character(at: $0) == 0x09 }
    }

    // MARK: tables

    /// What an empty table cell is made of: with the caret between the two, text typed into it is padded.
    static let blankCell = "  |"

    /// An empty table row for the lines after this one. Its cells are no wider than they must be:
    /// a cell's blanks count towards its column's width.
    func blankRow(columns: Int) -> String {
        continuation(startsItem: false) + "|" + String(repeating: Self.blankCell, count: columns)
    }

    /// Where the caret goes in a cell of a row made by `blankRow`: behind the cell's first space.
    func caretOffset(inBlankRowColumn column: Int) -> Int {
        (continuation(startsItem: false) as NSString).length + column * (Self.blankCell as NSString).length + 2
    }

    /// Return at the end of a paragraph line that reads as a header row of two or more cells adds
    /// the delimiter row and an empty first row.
    func tableStart(at selection: NSRange) -> TextEdit? {
        guard style.kind == .paragraph, selection.length == 0 else { return nil }
        let pipes = (contentStart..<contentEnd).filter {
            text.character(at: $0) == 0x7C && ($0 == contentStart || text.character(at: $0 - 1) != 0x5C)
        }
        guard pipes.count >= 3, let first = pipes.first, let last = pipes.last, selection.location > last,
              isBlank(contentStart..<first), isBlank(last + 1..<contentEnd) else { return nil }
        let lead = newline + continuation(startsItem: false)
        let rule = zip(pipes, pipes.dropFirst()).reduce(into: lead + "|") { rule, cell in
            let isPadded = cell.1 - cell.0 > 3 && isBlank(cell.0 + 1..<cell.0 + 2) && isBlank(cell.1 - 1..<cell.1)
            let dashes = String(repeating: "-", count: max(3, cell.1 - cell.0 - (isPadded ? 3 : 1)))
            rule += isPadded ? " \(dashes) |" : "\(dashes)|"
        }
        let caret = selection.location + (rule as NSString).length + (newline as NSString).length + caretOffset(inBlankRowColumn: 0)
        return TextEdit(range: NSRange(location: selection.location, length: contentEnd - selection.location),
                        replacement: rule + newline + blankRow(columns: pipes.count - 1), selection: NSRange(location: caret, length: 0))
    }

    /// Offset in the prefix of its last ">", or -1.
    private var lastQuote: Int {
        let found = prefix.range(of: ">", options: .backwards).location
        return found == NSNotFound ? -1 : found
    }

    /// The marker of the innermost container of `line`, when that is a list item starting on it.
    private func innermostMarker(of line: LineStyle) -> ListMarker? {
        let quote = (text.substring(with: line.prefixRange) as NSString).range(of: ">", options: .backwards).location
        return line.listMarkers.last.flatMap { quote == NSNotFound || $0.range.location - line.range.location > quote ? $0 : nil }
    }

    private var innermostMarker: ListMarker? { innermostMarker(of: style) }

    /// Whether a list item starts on this line that has no text yet.
    var startsEmptyItem: Bool { innermostMarker != nil && isBlank(contentStart..<contentEnd) }

    // MARK: Return

    /// What the next line needs in order to stay in this line's containers: the quote markers as they
    /// are and blanks for the rest, or with `startsItem` a fresh marker for the item that starts here.
    func continuation(startsItem: Bool) -> String {
        let result = NSMutableString(string: prefix)
        func blank(_ range: NSRange) {
            result.replaceCharacters(in: NSRange(location: range.location - start, length: range.length),
                                     with: String(repeating: " ", count: range.length))
        }
        let next = startsItem ? innermostMarker : nil
        for marker in style.listMarkers where marker != next {
            blank(marker.range)
            if let box = marker.checkbox { blank(box.range) }
        }
        if let marker = next {
            if let box = marker.checkbox { blank(NSRange(location: box.range.location + 1, length: 1)) }
            let digits = NSRange(location: marker.range.location, length: marker.range.length - 1)
            if marker.isOrdered, let number = Int(text.substring(with: digits)) {
                result.replaceCharacters(in: NSRange(location: digits.location - start, length: digits.length), with: String(number + 1))
            }
        }
        return result as String
    }

    private func fence(_ index: Int) -> (unit: unichar, length: Int, hasInfo: Bool)? {
        guard let marker = map.lines[index].fenceMarker else { return nil }
        let rest = NSRange(location: NSMaxRange(marker), length: NSMaxRange(map.lines[index].range) - NSMaxRange(marker))
        let info = text.substring(with: rest).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text.character(at: marker.location), marker.length, !info.isEmpty)
    }

    /// Whether the code block whose opening fence is on line `opening` wants a closing fence: it
    /// has none, or it ends at a later block's fence and has swallowed that block's opening line.
    private func isOpen(blockAt opening: Int, _ fence: (unit: unichar, length: Int, hasInfo: Bool)) -> Bool {
        var end = opening + 1
        var swallowsAnOpening = false
        while end < map.lines.count, case .codeBody = map.lines[end].kind {
            if let inner = self.fence(end), inner.unit == fence.unit, inner.length >= fence.length, inner.hasInfo {
                swallowsAnOpening = true
            }
            end += 1
        }
        let isClosed = end < map.lines.count && map.lines[end].kind == .codeFence(language: nil, isClosing: true)
        return !isClosed || swallowsAnOpening
    }

    /// Return at the end of an opening fence adds the closing one, unless the block already has its own.
    func closingFence(at selection: NSRange) -> TextEdit? {
        guard case .codeFence(_, isClosing: false) = style.kind, selection.length == 0,
              isBlank(selection.location..<contentEnd), let fence = fence(index), isOpen(blockAt: index, fence) else { return nil }
        let body = newline + continuation(startsItem: false)
        let closing = body + String(repeating: String(UnicodeScalar(fence.unit)!), count: fence.length)
        return TextEdit(range: selection, replacement: body + closing,
                        selection: NSRange(location: selection.location + (body as NSString).length, length: 0))
    }

    /// Return at the end of a closing fence that was typed by hand right above the one Return had
    /// added: that one, which is hidden and now opens a block of its own that nothing closes, is
    /// typed over instead of being left behind.
    func typedOverFence(at selection: NSRange) -> TextEdit? {
        guard style.kind == .codeFence(language: nil, isClosing: true), selection == NSRange(location: contentEnd, length: 0),
              let fence = fence(index), let next, case .codeFence(_, isClosing: false) = next.kind, next.containers == style.containers,
              let added = self.fence(index + 1), added.unit == fence.unit, added.length == fence.length, !added.hasInfo,
              isOpen(blockAt: index + 1, added) else { return nil }
        let body = newline + continuation(startsItem: false)
        return TextEdit(range: NSRange(location: contentEnd, length: text.lineContentEnd(at: next.range.location) - contentEnd), replacement: body,
                        selection: NSRange(location: contentEnd + (body as NSString).length, length: 0))
    }

    // MARK: leaving a container

    /// Removes the innermost block marker from the line: a task's checkbox (the whole item with
    /// `wholeItem`), a nested item's indentation, a list marker, the indentation of a continuation
    /// line or of indented code, or a ">".
    /// What is left would be read as more of a paragraph directly above, so a blank line goes between.
    func unwrapped(wholeItem: Bool) -> TextEdit? {
        let prefix = prefix
        /// Where the last ">" ends, with the space that belongs to it.
        let afterQuote = lastQuote + (lastQuote >= 0 && lastQuote + 1 < prefix.length && prefix.character(at: lastQuote + 1) == 0x20 ? 2 : 1)
        var keep = prefix.length
        if let marker = innermostMarker {
            if !wholeItem, let box = marker.checkbox {
                return TextEdit(range: NSRange(location: box.range.location, length: contentStart - box.range.location),
                                replacement: "", selection: NSRange(location: box.range.location, length: 0))
            }
            if let edit = shifted(deeper: false, selection: NSRange(location: contentStart, length: 0)) { return edit }
            keep = marker.range.location - start
        }
        while keep > afterQuote, isBlank(start + keep - 1..<start + keep) { keep -= 1 }
        // Nothing came after the ">", so that is the marker to remove.
        if keep == prefix.length { keep = max(lastQuote, 0) }
        var kept = prefix.substring(to: keep)
        let keepsAMarker = style.listMarkers.first.map { $0.range.location - start < keep } ?? false
        if previous?.kind == .paragraph, !keepsAMarker {
            kept = kept.trimmingTrailingBlanks + newline + kept
        }
        return TextEdit(range: style.prefixRange, replacement: kept,
                        selection: NSRange(location: start + (kept as NSString).length, length: 0))
    }

    // MARK: Tab

    /// Offset from the line start of the first character that is not indentation or a quote marker.
    private func textColumn(_ line: LineStyle) -> Int {
        var i = line.range.location
        while i < NSMaxRange(line.range), [0x20, 0x09, 0x3E].contains(text.character(at: i)) { i += 1 }
        return i - line.range.location
    }

    private func isEmpty(_ line: LineStyle) -> Bool { line.kind == .blank && line.listMarkers.isEmpty }

    /// The number of the list item whose marker is at `column` of `line`; nil for a bullet.
    private func number(of line: LineStyle, at column: Int) -> (value: Int, digits: Int)? {
        let from = line.range.location + column
        var digits = 0
        while from + digits < NSMaxRange(line.range), (0x30...0x39).contains(text.character(at: from + digits)) { digits += 1 }
        return Int(text.substring(with: NSRange(location: from, length: digits))).map { ($0, digits) }
    }

    /// The offset from its line's start of the marker of the list item that starts on the line at
    /// `index`. That is also a marker alone on its line inside a list item, directly below text:
    /// the parser cannot take it for an item (an empty item does not interrupt a paragraph, and
    /// "-" there reads as a heading's underline), but it is what Tab on an empty item leaves.
    private func markerColumn(ofLineAt index: Int) -> Int? {
        let line = map.lines[index]
        if !line.listMarkers.isEmpty { return innermostMarker(of: line).map { $0.range.location - line.range.location } }
        guard line.listDepth > 0, line.kind == .paragraph || line.kind == .headingUnderline(level: 2) else { return nil }
        let column = textColumn(line), from = line.range.location + column
        let rest = text.substring(with: NSRange(location: from, length: text.lineContentEnd(at: from) - from)).trimmingTrailingBlanks
        let digits = number(of: line, at: column)?.digits ?? 0
        return ["-", "+", "*"].contains(rest) || digits > 0 && [".", ")"].contains(rest.dropFirst(digits)) ? column : nil
    }

    /// Where the marker ends that stands alone on this line without being an item to the parser
    /// (see `markerColumn`): behind it the keys take the line for the empty item it is to the eye.
    var loneMarkerEnd: Int? {
        guard style.listMarkers.isEmpty, let column = markerColumn(ofLineAt: index) else { return nil }
        return start + column + (number(of: style, at: column)?.digits ?? 0) + 1
    }

    /// The line on which the list item starts that the line at `index` is in.
    private func itemStart(ofLineAt index: Int) -> Int? {
        if markerColumn(ofLineAt: index) != nil { return index }
        let line = map.lines[index]
        guard line.listDepth > 0 else { return nil }
        return map.lines[..<index].lastIndex { $0.containers == line.containers && innermostMarker(of: $0) != nil }
    }

    /// Where Tab or Shift-Tab moves the item whose marker is at `column` of the line at `index`:
    /// the column its marker goes to, under the item before it or at its parent's, and the
    /// number of the item that it then follows, if that has one. Nil when there is no such place.
    private func destination(ofItemAt index: Int, column: Int, deeper: Bool) -> (column: Int, before: Int?)? {
        /// The items passed on the way up, which are nested in the item before this one.
        var nested: [(column: Int, number: Int?)] = []
        for other in map.lines[..<index].reversed() where !isEmpty(other) {
            guard other.listDepth > 0 else { break }
            guard let marker = other.listMarkers.last else { continue }
            let otherColumn = marker.range.location - other.range.location
            if otherColumn > column || !deeper && otherColumn == column {
                nested.append((otherColumn, number(of: other, at: otherColumn)?.value))
            } else if deeper, otherColumn == column {
                let content = marker.checkbox?.range.location ?? max(NSMaxRange(other.prefixRange), NSMaxRange(marker.range) + 1)
                let target = content - other.range.location
                return (target, nested.first { $0.column == target }?.number)
            } else {
                return deeper ? nil : (otherColumn, number(of: other, at: otherColumn)?.value)
            }
        }
        return nil
    }

    /// Tab and Shift-Tab in a list. Every item that starts on a line of the selection, and the
    /// item the selection starts in, moves under the item before it or out to its parent's level,
    /// with everything nested in it; an item that has nowhere to go stays. A numbered item takes
    /// the number after the item it then follows, and 1 where it starts a list under an item:
    /// only a list that starts with 1 can begin directly below text. Nil when nothing moves.
    func shifted(deeper: Bool, selection: NSRange) -> TextEdit? {
        let last = selection.length > 0 ? map.lineIndex(containing: NSMaxRange(selection) - 1) ?? index : index
        var changes: [Change] = []
        /// Where the numbered item moved last went, and its number there.
        var numbered: (column: Int, number: Int)?
        var current = itemStart(ofLineAt: index) ?? index
        while current <= last {
            guard let column = markerColumn(ofLineAt: current),
                  let (target, before) = destination(ofItemAt: current, column: column, deeper: deeper) else {
                current += 1
                continue
            }
            // With everything nested in it.
            var end = current + 1
            while end < map.lines.count, isEmpty(map.lines[end]) || textColumn(map.lines[end]) > column { end += 1 }
            /// How far everything moves; what is nested in an item whose number gets longer or
            /// shorter moves with the item's text, which is that much further.
            var shift = target - column
            for line in map.lines[current..<end] where !isEmpty(line) {
                let from = line.range.location
                guard shift >= 0 || isBlank(from + column + shift..<from + column) else { continue }
                var change = Change(range: NSRange(location: from + column + min(shift, 0), length: max(-shift, 0)),
                                    text: String(repeating: " ", count: max(shift, 0)))
                if line == map.lines[current], let old = number(of: line, at: column),
                   let new = (numbered.flatMap { $0.column == target ? $0.number : nil } ?? before ?? (deeper ? 0 : nil)).map({ $0 + 1 }) {
                    change.range.length = from + column + old.digits - change.range.location
                    change.text += String(new)
                    numbered = (target, new)
                    shift += String(new).count - old.digits
                }
                if shift != 0 || change.range.length > 0 { changes.append(change) }
            }
            current = end
        }
        return TextEdit.combining(changes, in: text, selection: selection)
    }

    // MARK: code

    /// Languages in which a line that ends with a colon opens a block.
    private static let colonLanguages: Set<String> = ["python", "py", "python3", "starlark", "gdscript", "nim", "coffee", "coffeescript", "yaml", "yml"]

    /// Where the content of `line` starts and ends, and how many blanks it starts with.
    private func indentation(of line: LineStyle) -> (start: Int, blanks: Int, end: Int) {
        let start = NSMaxRange(line.prefixRange), end = text.lineContentEnd(at: line.range.location)
        var blanks = 0
        while start + blanks < end, isBlank(start + blanks..<start + blanks + 1) { blanks += 1 }
        return (start, blanks, end)
    }

    /// One level of indentation in the code block that the line at `index` is in: a tab where a
    /// line of the block starts with one, else the least by which two lines of it that follow
    /// one another differ (an excerpt may be indented as a whole), else the least that a line of
    /// it is indented by, else four spaces.
    private func indentUnit(ofBlockAt index: Int) -> String {
        var first = index, last = index
        while first > 0, case .codeBody = map.lines[first - 1].kind { first -= 1 }
        while last + 1 < map.lines.count, case .codeBody = map.lines[last + 1].kind { last += 1 }
        var least = 0, step = 0, previous: Int?
        for line in map.lines[first...last] {
            let from = NSMaxRange(line.prefixRange), end = text.lineContentEnd(at: line.range.location)
            var count = 0
            while from + count < end, text.character(at: from + count) == 0x20 { count += 1 }
            guard from + count < end else { continue }
            if text.character(at: from + count) == 0x09 { return "\t" }
            if count > 0, least == 0 || count < least { least = count }
            if let previous, count != previous, step == 0 || abs(count - previous) < step { step = abs(count - previous) }
            previous = count
        }
        return String(repeating: " ", count: step > 0 ? step : least > 0 ? least : 4)
    }

    /// What Return at `location` in a line of code starts the next line with: the blanks this
    /// line starts with, and one level more when what stands before `location` opens a block:
    /// it leaves a bracket open or, in a language like Python, ends with a colon. Strings and
    /// comments do not count, as far as the block's language is known. Empty outside code.
    func codeIndentation(before location: Int) -> String {
        guard case .codeBody(let language) = style.kind else { return "" }
        let blanks = min(indentation(of: style).blanks, location - contentStart)
        var open = 0, lastCode: unichar = 0
        for offset in contentStart + blanks..<location {
            let unit = text.character(at: offset)
            guard unit != 0x20, unit != 0x09, !style.codeTokens.contains(where: {
                ($0.kind == .string || $0.kind == .comment) && NSLocationInRange(offset, $0.range)
            }) else { continue }
            lastCode = unit
            if [0x28, 0x5B, 0x7B].contains(unit) { open += 1 }
            if [0x29, 0x5D, 0x7D].contains(unit) { open = max(open - 1, 0) }
        }
        let opens = open > 0 || lastCode == 0x3A && Self.colonLanguages.contains(language?.lowercased() ?? "")
        return text.substring(with: NSRange(location: contentStart, length: blanks)) + (opens ? indentUnit(ofBlockAt: index) : "")
    }

    /// How many of the `blanks` in front of `location`, which reach back to where a line's
    /// content starts, one level of indentation is where that is `unit`: a tab, or the spaces
    /// back to the last whole level.
    private func level(of blanks: Int, before location: Int, unit: String) -> Int {
        guard blanks > 0 else { return 0 }
        guard text.character(at: location - 1) == 0x20 else { return 1 }
        var spaces = 0
        while spaces < blanks, text.character(at: location - 1 - spaces) == 0x20 { spaces += 1 }
        return unit == "\t" ? 1 : min(spaces, (blanks - 1) % (unit as NSString).length + 1)
    }

    /// Backspace among the blanks a line of code starts with takes one level of indentation.
    func codeUnindented(at location: Int) -> TextEdit? {
        guard case .codeBody = style.kind, location - contentStart <= indentation(of: style).blanks,
              case let count = level(of: location - contentStart, before: location, unit: indentUnit(ofBlockAt: index)), count > 0 else { return nil }
        return TextEdit(range: NSRange(location: location - count, length: count), replacement: "", selection: NSRange(location: location - count, length: 0))
    }

    /// Tab and Shift-Tab in a code block: one level of indentation at the caret or in place of a
    /// selection within the line, and one more or less for every line of code that a longer
    /// selection reaches, also one that starts above the code: on its fence or in text outside
    /// any list (in a list the items move, with their code). Nil where the selection has no
    /// such line; in code the key never means anything else.
    func codeIndented(deeper: Bool, selection: NSRange) -> TextEdit? {
        let last = selection.length > 0 ? map.lineIndex(containing: NSMaxRange(selection) - 1) ?? index : index
        func isCode(_ index: Int) -> Bool { if case .codeBody = map.lines[index].kind { true } else { false } }
        guard isCode(index) || style.listDepth == 0, let first = (index...last).first(where: isCode) else { return nil }
        let unit = indentUnit(ofBlockAt: first), length = (unit as NSString).length
        if deeper, last == index {
            return TextEdit(range: selection, replacement: unit, selection: NSRange(location: selection.location + length, length: 0))
        }
        var changes: [Change] = []
        for line in map.lines[first...last] {
            guard case .codeBody = line.kind, case let (start, blanks, end) = indentation(of: line), start < end else { continue }
            if deeper {
                // A selection that starts in front of a line goes on doing so.
                changes.append(Change(range: NSRange(location: start, length: 0), text: unit, pushes: false))
            } else if case let count = level(of: min(blanks, length), before: start + min(blanks, length), unit: unit), count > 0 {
                changes.append(Change(range: NSRange(location: start, length: count), text: ""))
            }
        }
        return TextEdit.combining(changes, in: text, selection: selection)
            ?? TextEdit(range: NSRange(location: selection.location, length: 0), replacement: "", selection: selection)
    }
}
