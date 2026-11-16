import Foundation

public enum FormatCommand: Hashable, Sendable {
    case bold, italic, strikethrough, code, link, image
    /// Level 1 to 6.
    case heading(Int)
    case paragraph, increaseHeading, decreaseHeading
    case bulletList, orderedList, taskList, quote, codeBlock, rule, table
}

/// The Format menu as string transforms. Like `InputRules`, each is a pure function of the text,
/// its style map and the selection; nil means the command does not apply there. A command that is
/// on at the selection (`isOn`) is taken off again by its edit.
public enum FormatCommands {
    public static func edit(_ command: FormatCommand, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard let target = Target(text, map, selection) else { return nil }
        switch command {
        case .bold: return target.toggling(.strong, "**")
        case .italic: return target.toggling(.emphasis, "*")
        case .strikethrough: return target.toggling(.strikethrough, "~~")
        case .code: return target.toggling(.code, "`")
        case .link: return target.togglingLink(isImage: false)
        case .image: return target.togglingLink(isImage: true)
        case .heading(let level):
            let isOn = target.textLines.allSatisfy { target.headingLevel($0) == level }
            return target.heading { _ in isOn ? 0 : level }
        case .paragraph: return target.heading { _ in 0 }
        case .increaseHeading: return target.heading { $0 == 0 ? 6 : max($0 - 1, 1) }
        case .decreaseHeading: return target.heading { $0 == 0 ? 0 : ($0 + 1) % 7 }
        case .bulletList: return target.list(.bullet)
        case .orderedList: return target.list(.ordered)
        case .taskList: return target.list(.task)
        case .quote: return target.quote()
        case .codeBlock: return target.codeBlock()
        case .rule: return target.inserting(["---"], caret: nil)
        case .table:
            let row = "|   |   |   |"
            return target.inserting([row, "|---|---|---|", row, row], caret: (0, 2))
        }
    }

    /// Whether the selection already has what `command` gives: the menu's checkmark.
    public static func isOn(_ command: FormatCommand, in text: String, map: StyleMap, selection: NSRange) -> Bool {
        guard let target = Target(text, map, selection) else { return false }
        switch command {
        case .bold: return target.token(.strong) != nil
        case .italic: return target.token(.emphasis) != nil
        case .strikethrough: return target.token(.strikethrough) != nil
        case .code: return target.token(.code) != nil
        case .link: return target.token(.link) != nil
        case .image: return target.token(.image) != nil
        case .heading(let level): return target.textLines.allSatisfy { target.headingLevel($0) == level }
        case .paragraph: return target.textLines.allSatisfy { target.style($0).kind == .paragraph }
        case .bulletList: return target.textLines.allSatisfy { target.listKind($0) == .bullet }
        case .orderedList: return target.textLines.allSatisfy { target.listKind($0) == .ordered }
        case .taskList: return target.textLines.allSatisfy { target.listKind($0) == .task }
        case .quote: return target.textLines.allSatisfy { target.quoteMarker($0) != nil }
        case .codeBlock: return target.isCode(target.lines.lowerBound)
        case .increaseHeading, .decreaseHeading, .rule, .table: return false
        }
    }

    public static let wrappingMarkers: Set = ["`", "*", "_", "~"]

    /// One of `wrappingMarkers` typed with text selected goes around the selection.
    public static func wrap(_ typed: String, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        guard selection.length > 0, wrappingMarkers.contains(typed), let target = Target(text, map, selection),
              let range = target.wrappable else { return nil }
        return target.wrapping(range, typed, typed, selection: NSRange(location: range.location + 1, length: range.length))
    }

    /// A URL pasted over selected text makes that text a link to it.
    public static func link(pasting pasted: String, in text: String, map: StyleMap, selection: NSRange) -> TextEdit? {
        let url = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection.length > 0, isURL(url), let target = Target(text, map, selection), target.lines.count == 1,
              let range = target.wrappable, target.token(.link) == nil, target.token(.image) == nil,
              !isURL((text as NSString).substring(with: range)) else { return nil }
        let close = "](\(url))"
        return target.wrapping(range, "[", close, selection: NSRange(location: NSMaxRange(range) + 1 + (close as NSString).length, length: 0))
    }

    /// The source of an image at `path`; see `linkMarkup`.
    public static func imageMarkup(alt: String, path: String) -> String {
        "!" + linkMarkup(text: alt, path: path)
    }

    /// The source of a link to `path` that shows `text`. In the text, the characters that Markdown
    /// reads as markup are escaped, the backslash first. In the destination, those that would end
    /// it, or that are read as an escape, as markup, as an entity or as the start of a fragment
    /// when it is resolved, are percent-encoded, the percent sign first.
    public static func linkMarkup(text: String, path: String) -> String {
        let shown = "\\[]`*_<&".reduce(text) { $0.replacingOccurrences(of: String($1), with: "\\\($1)") }
        let destination = "%# ()\\`&<>".unicodeScalars.reduce(path) {
            $0.replacingOccurrences(of: String($1), with: String(format: "%%%02X", $1.value))
        }
        return "[\(shown)](\(destination))"
    }

    static func isURL(_ string: String) -> Bool {
        string.range(of: #"^([A-Za-z][A-Za-z0-9+.-]*://|mailto:)\S+$"#, options: .regularExpression) != nil
    }
}

/// The lines the selection touches.
private struct Target {
    enum ListKind { case bullet, ordered, task }

    let source: String
    let text: NSString
    let map: StyleMap
    let selection: NSRange
    /// Indices into the map's lines. One past its last line stands for the empty line after the
    /// text's final terminator, which the map has no entry for.
    let lines: ClosedRange<Int>

    init?(_ source: String, _ map: StyleMap, _ selection: NSRange) {
        let text = source as NSString
        // As in `Line`: a map as long as the text has every range inside it.
        guard NSMaxRange(selection) <= text.length, (map.lines.last.map { NSMaxRange($0.range) } ?? 0) == text.length else { return nil }
        func index(_ location: Int) -> Int? {
            let endsWithTerminator = text.length == 0 || [0x0A, 0x0D].contains(text.character(at: text.length - 1))
            return location == text.length && endsWithTerminator ? map.lines.count : map.lineIndex(containing: location)
        }
        // A selection that ends at the start of a line does not touch that line.
        guard let first = index(selection.location),
              let last = selection.length > 0 ? index(NSMaxRange(selection) - 1) : first, first <= last else { return nil }
        self.source = source
        self.text = text
        self.map = map
        self.selection = selection
        lines = first...last
        guard style(first).range == text.lineRange(for: NSRange(location: selection.location, length: 0)) else { return nil }
    }

    func style(_ index: Int) -> LineStyle {
        guard index < map.lines.count else {
            var line = LineStyle(range: NSRange(location: text.length, length: 0))
            line.kind = .blank
            return line
        }
        return map.lines[index]
    }

    func contentStart(_ index: Int) -> Int { NSMaxRange(style(index).prefixRange) }

    func contentEnd(_ index: Int) -> Int { text.lineContentEnd(at: style(index).range.location) }

    /// The line break to insert: that of the first line, or of the line above when it has none.
    var newline: String {
        for index in [lines.lowerBound, lines.lowerBound - 1] where index >= 0 {
            let end = contentEnd(index), next = NSMaxRange(style(index).range)
            if next > end { return text.substring(with: NSRange(location: end, length: next - end)) }
        }
        return "\n"
    }

    /// What a line after the line at `index` starts with to stay in its containers.
    func continuation(_ index: Int) -> String {
        Line(source, map, at: style(index).range.location)?.continuation(startsItem: false) ?? ""
    }

    func isCode(_ index: Int) -> Bool {
        switch style(index).kind {
        case .codeFence, .codeBody: true
        default: false
        }
    }

    private func isTable(_ index: Int) -> Bool {
        switch style(index).kind {
        case .tableRow, .tableDelimiter: true
        default: false
        }
    }

    /// A blank line that is not an empty list item.
    private func isEmpty(_ index: Int) -> Bool {
        style(index).kind == .blank && style(index).listMarkers.isEmpty
    }

    /// The selected lines that hold something. A selection of blank lines only is its first line.
    var textLines: [Int] {
        let lines = self.lines.filter { !isEmpty($0) }
        return lines.isEmpty ? [self.lines.lowerBound] : lines
    }

    /// Replaces the union of `changes`, which are in order and apart, and carries the selection along.
    private func edit(_ changes: [Change], selection: NSRange? = nil) -> TextEdit? {
        var edit = TextEdit.combining(changes, in: text, selection: self.selection)
        if let selection { edit?.selection = selection }
        return edit
    }

    // MARK: inline

    /// Whether inline markers mean anything on the selected lines: not in code, and a selection
    /// stays inside one table cell or, over several lines, inside one paragraph.
    var takesInlineMarkers: Bool {
        let first = style(lines.lowerBound)
        guard lines.count == 1 else {
            return lines.allSatisfy { style($0).kind == .paragraph && style($0).containers == first.containers }
                && lines.dropFirst().allSatisfy { style($0).listMarkers.isEmpty }
        }
        switch first.kind {
        case .paragraph, .heading, .blank: return true
        case .tableRow:
            return first.cells.contains { $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range) }
        default: return false
        }
    }

    /// The selected text that markers go around: without the line's block and heading markers and
    /// without blanks and line breaks at its ends. A caret is itself.
    private var marked: NSRange {
        guard selection.length > 0 else { return selection }
        let first = style(lines.lowerBound), closing = style(lines.upperBound).headingMarkers.dropFirst().first
        var start = max(selection.location, first.headingMarkers.first.map(NSMaxRange) ?? contentStart(lines.lowerBound))
        var end = max(start, min(NSMaxRange(selection), closing?.location ?? .max))
        let blanks = CharacterSet.whitespacesAndNewlines
        func isBlank(_ offset: Int) -> Bool { UnicodeScalar(text.character(at: offset)).map(blanks.contains) ?? false }
        while start < end, isBlank(start) { start += 1 }
        while end > start, isBlank(end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    /// Whether markers around `range` would cut into text where they are not read as markers or
    /// break what is there: a code span, an autolink, or the destination of a link or image.
    private func cutsLiteral(_ range: NSRange) -> Bool {
        lines.contains { index in
            style(index).tokens.contains { token in
                let literals: [NSRange]
                switch token.kind {
                case .code, .html: literals = [token.range]
                case .link where text.character(at: token.range.location) == 0x3C: literals = [token.range]
                case .link, .image: literals = token.markerRanges
                default: literals = []
                }
                return literals.contains {
                    range.location < NSMaxRange($0) && NSMaxRange(range) > $0.location
                        && !(range.location <= $0.location && NSMaxRange(range) >= NSMaxRange($0))
                }
            }
        }
    }

    /// What a typed marker or a pasted URL goes around, when the selection can take it.
    var wrappable: NSRange? {
        let range = marked
        return range.length > 0 && takesInlineMarkers && !cutsLiteral(range) ? range : nil
    }

    /// The pieces of the innermost construct of `kind` that holds the whole selection.
    func token(_ kind: InlineToken.Kind) -> [InlineToken]? {
        let selection = marked
        guard let found = style(lines.lowerBound).tokens.last(where: {
            $0.kind == kind && $0.range.location <= selection.location && NSMaxRange(selection) <= NSMaxRange($0.range)
        }), let first = map.lineIndex(containing: found.range.location),
            let last = map.lineIndex(containing: NSMaxRange(found.range) - 1) else { return nil }
        return map.lines[first...last].flatMap { $0.tokens.filter { $0.kind == kind && $0.range == found.range } }
    }

    private func removing(_ pieces: [InlineToken]) -> TextEdit? {
        edit(pieces.flatMap(\.markerRanges).sorted { $0.location < $1.location }.map { Change(range: $0, text: "") })
    }

    func wrapping(_ range: NSRange, _ open: String, _ close: String, selection: NSRange) -> TextEdit? {
        edit([Change(range: NSRange(location: range.location, length: 0), text: open),
              Change(range: NSRange(location: NSMaxRange(range), length: 0), text: close)], selection: selection)
    }

    /// The selected text, or the word the caret is in or beside.
    private var inlineRange: NSRange {
        guard selection.length == 0 else { return marked }
        var start = selection.location, end = start
        let letters = CharacterSet.alphanumerics
        func isLetter(_ offset: Int) -> Bool {
            let unit = text.character(at: offset)
            return UTF16.isLeadSurrogate(unit) || UTF16.isTrailSurrogate(unit) || UnicodeScalar(unit).map(letters.contains) ?? false
        }
        let line = lines.lowerBound
        while start > contentStart(line), isLetter(start - 1) { start -= 1 }
        while end < contentEnd(line), isLetter(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// How many times `unit` stands directly before or after the caret.
    private func run(of unit: unichar, forward: Bool) -> Int {
        var count = 0
        let caret = selection.location
        while forward ? caret + count < text.length && text.character(at: caret + count) == unit
                : caret - count > 0 && text.character(at: caret - count - 1) == unit { count += 1 }
        return count
    }

    func toggling(_ kind: InlineToken.Kind, _ marker: String) -> TextEdit? {
        // An empty pair alone on its line reads as a rule ("****") or a fence ("~~~~") until text is typed into it.
        let line = lines.lowerBound, unit = (marker as NSString).character(at: 0)
        let content = NSRange(location: contentStart(line), length: contentEnd(line) - contentStart(line))
        var isPairAlone = text.substring(with: content) == marker + marker
        if case .codeBody = style(line).kind { isPairAlone = false }
        guard takesInlineMarkers || isPairAlone else { return nil }
        if let pieces = token(kind) { return removing(pieces) }
        let range = inlineRange, length = (marker as NSString).length
        guard !cutsLiteral(range) else { return nil }
        if range.length > 0 {
            let inner = selection.length > 0 ? range : selection
            return wrapping(range, marker, marker, selection: NSRange(location: inner.location + length, length: inner.length))
        }
        guard selection.length == 0 else { return nil }
        // An empty pair is not a construct the parser knows, so the text tells whether the caret is in one.
        let before = run(of: unit, forward: false), after = run(of: unit, forward: true)
        // One "*" is emphasis only where the run is not made of "**" pairs.
        if min(before, after) >= length, marker != "*" || (before % 2 == 1 && after % 2 == 1) {
            return TextEdit(range: NSRange(location: selection.location - length, length: 2 * length), replacement: "",
                            selection: NSRange(location: selection.location - length, length: 0))
        }
        return TextEdit(range: selection, replacement: marker + marker, selection: NSRange(location: selection.location + length, length: 0))
    }

    /// Makes the selection or the word at the caret the text of a link, with the caret where the
    /// destination goes; with nothing to make a link of, the caret is where its text goes. For an
    /// image the text is its description.
    func togglingLink(isImage: Bool) -> TextEdit? {
        guard takesInlineMarkers, lines.count == 1 else { return nil }
        if let pieces = token(isImage ? .image : .link) { return removing(pieces) }
        let range = inlineRange, open = isImage ? "![" : "["
        guard !cutsLiteral(range) else { return nil }
        let destination = NSMaxRange(range) + (open as NSString).length + 2
        let caret = range.length > 0 || isImage ? destination : range.location + 1
        return wrapping(range, open, "]()", selection: NSRange(location: caret, length: 0))
    }

    // MARK: headings

    /// 0 for text that is not a heading, nil for a line that cannot become one.
    func headingLevel(_ index: Int) -> Int? {
        let line = style(index)
        switch line.kind {
        case .paragraph, .blank: return 0
        case .heading(let level) where !line.headingMarkers.isEmpty || underline(of: index) != nil: return level
        case .headingUnderline(let level) where index > 0 && underline(of: index - 1) == index: return level
        default: return nil
        }
    }

    /// The line that underlines the heading at `index`, when that is a setext heading of one
    /// line. Only such a one can be written with "#" instead, or without its underline.
    private func underline(of index: Int) -> Int? {
        func isSetext(_ index: Int) -> Bool {
            if case .heading = style(index).kind { return style(index).headingMarkers.isEmpty }
            return false
        }
        guard isSetext(index), !(index > 0 && isSetext(index - 1)), index + 1 < map.lines.count,
              case .headingUnderline = style(index + 1).kind else { return nil }
        return index + 1
    }

    /// Gives every selected line the heading level `level` makes of its current one. Not behind a
    /// checkbox, where "#" is text. A setext heading loses its underline for it.
    func heading(_ level: (Int) -> Int) -> TextEdit? {
        var changes: [Change] = [], done: Set<Int> = []
        for selected in textLines {
            // The underline alone stands for the heading it underlines.
            var index = selected
            if case .headingUnderline = style(index).kind { index -= 1 }
            guard index >= 0, done.insert(index).inserted else { continue }
            guard let current = headingLevel(index), style(index).listMarkers.last?.checkbox == nil else { return nil }
            let new = level(current), markers = style(index).headingMarkers
            guard new != current else { continue }
            let marker = new == 0 ? "" : String(repeating: "#", count: new) + " "
            changes.append(Change(range: markers.first ?? NSRange(location: contentStart(index), length: 0), text: marker))
            if new == 0, markers.count > 1 { changes.append(Change(range: markers[1], text: "")) }
            guard let under = underline(of: index) else { continue }
            // Text directly below the underline would join a paragraph: there the line stays, empty.
            let joins = new == 0 && under + 1 < map.lines.count && style(under + 1).kind != .blank
            let start = joins ? contentStart(under) : contentEnd(index)
            changes.append(Change(range: NSRange(location: start, length: contentEnd(under) - start), text: ""))
        }
        return edit(changes)
    }

    // MARK: lists and quotes

    /// The marker of the line's innermost container, when that is a list item starting on the line.
    private func ownMarker(_ index: Int) -> ListMarker? {
        guard let marker = style(index).listMarkers.last else { return nil }
        return quoteMarker(index).map { $0 < marker.range.location } ?? true ? marker : nil
    }

    func listKind(_ index: Int) -> ListKind? {
        ownMarker(index).map { $0.checkbox != nil ? .task : $0.isOrdered ? .ordered : .bullet }
    }

    /// Offset of the last ">" among the line's block markers.
    func quoteMarker(_ index: Int) -> Int? {
        let prefix = style(index).prefixRange
        let found = text.range(of: ">", options: .backwards, range: prefix).location
        return found == NSNotFound ? nil : found
    }

    /// The block markers of the line at `index` up to `marker`, as a blank line carries them.
    private func blankPrefix(_ index: Int, upTo marker: Int) -> String {
        let start = style(index).range.location
        return text.substring(with: NSRange(location: start, length: marker - start)).trimmingTrailingBlanks
    }

    /// What goes in front of a line that would be read as more of a paragraph directly above it,
    /// once its markers from `marker` on are gone or changed: a blank line in the same containers.
    private func separator(before index: Int, marker: Int) -> [Change] {
        guard index > 0, index <= map.lines.count, style(index - 1).kind == .paragraph else { return [] }
        return [Change(range: NSRange(location: style(index).range.location, length: 0), text: blankPrefix(index, upTo: marker) + newline)]
    }

    func list(_ kind: ListKind) -> TextEdit? {
        let targets = textLines
        guard targets.allSatisfy({ headingLevel($0) != nil }) else { return nil }
        let isOn = targets.allSatisfy { listKind($0) == kind }
        var changes: [Change] = []
        for (number, index) in targets.enumerated() {
            let end = contentStart(index), marker = ownMarker(index)
            let start = marker?.range.location ?? end
            var replacement = ""
            if !isOn {
                let bullet = marker.flatMap { $0.isOrdered ? nil : text.substring(with: $0.range) } ?? "-"
                switch kind {
                case .bullet: replacement = bullet + " "
                case .ordered: replacement = "\(number + 1). "
                case .task: replacement = "\(bullet) \(marker?.checkbox.map { text.substring(with: $0.range) } ?? "[ ]") "
                }
            }
            // An empty item cannot start below a paragraph: "-" there underlines it as a heading.
            if number == 0, isOn || isEmpty(index) { changes += separator(before: index, marker: start) }
            changes.append(Change(range: NSRange(location: start, length: end - start), text: replacement))
        }
        // A numbered item other than "1." does not start a list below a paragraph, so the items
        // after the ones that lost their numbers are kept apart from them.
        if isOn, let last = targets.last, last + 1 < map.lines.count, let next = ownMarker(last + 1), next.isOrdered {
            changes.append(Change(range: NSRange(location: contentEnd(last), length: 0),
                                  text: newline + blankPrefix(last + 1, upTo: next.range.location), pushes: false))
        }
        return edit(changes)
    }

    func quote() -> TextEdit? {
        let targets = textLines
        guard let first = targets.first, let last = targets.last else { return nil }
        var changes: [Change] = []
        if targets.allSatisfy({ quoteMarker($0) != nil }) {
            for index in first...last {
                guard let marker = quoteMarker(index) else { continue }
                // A list marker left behind starts its item below a paragraph as it is.
                if index == first, ownMarker(index) == nil { changes += separator(before: index, marker: marker) }
                let hasSpace = marker + 1 < contentEnd(index) && text.character(at: marker + 1) == 0x20
                changes.append(Change(range: NSRange(location: marker, length: hasSpace ? 2 : 1), text: ""))
            }
        } else {
            // Inside a list item the marker goes behind the indentation that keeps the line in the
            // item: in front of it the line would leave the item. All lines get it in one column.
            func column(_ index: Int) -> Int {
                let line = style(index)
                return line.listDepth == 0 ? 0 : (line.listMarkers.first?.range.location ?? contentStart(index)) - line.range.location
            }
            let column = targets.map(column).min() ?? 0
            // The blank lines in between get a marker too, which keeps it one quote.
            for index in first...last {
                let start = style(index).range.location, indent = min(column, contentEnd(index) - start)
                let marker = String(repeating: " ", count: column - indent) + (isEmpty(index) && first != last ? ">" : "> ")
                changes.append(Change(range: NSRange(location: start + indent, length: 0), text: marker))
            }
        }
        return edit(changes)
    }

    // MARK: blocks

    func codeBlock() -> TextEdit? {
        let first = lines.lowerBound, last = lines.upperBound
        if isCode(first) { return unfenced() }
        // One fence holds the lines only when they all lie in the first line's containers and none
        // starts a list item of its own there. Behind a checkbox a fence is text.
        let base = style(first)
        guard lines.allSatisfy({ !isCode($0) }), base.listMarkers.last?.checkbox == nil,
              lines.dropFirst().allSatisfy({
                  let line = style($0)
                  return isEmpty($0) || line.containers.starts(with: base.containers)
                      && line.listMarkers.count <= line.containers.count - base.containers.count
              }) else { return nil }
        let lead = newline + continuation(first)
        return edit([Change(range: NSRange(location: contentStart(first), length: 0), text: "```" + lead),
                     Change(range: NSRange(location: contentEnd(last), length: 0), text: lead + "```", pushes: false)])
    }

    /// Removes the fences of the block the selection starts in. Indented code has none.
    private func unfenced() -> TextEdit? {
        var open = lines.lowerBound
        if case .codeFence(_, isClosing: true) = style(open).kind { open -= 1 }
        while open > 0, case .codeBody = style(open).kind { open -= 1 }
        guard open >= 0, case .codeFence(_, isClosing: false) = style(open).kind else { return nil }
        var close = open + 1
        while close < map.lines.count, case .codeBody = style(close).kind { close += 1 }
        let isClosed = close < map.lines.count && style(close).kind == .codeFence(language: nil, isClosing: true)
        let hasBody = open + 1 < map.lines.count && isCode(open + 1)

        // The opening fence goes with its line break and the next line's markers, so that the first
        // line of code takes its place behind a list marker.
        let start = contentStart(open)
        var changes = [Change(range: NSRange(location: start, length: (hasBody ? contentStart(open + 1) : contentEnd(open)) - start), text: "")]
        if isClosed {
            let line = style(close).range, end = contentEnd(close)
            if close == open + 1 {
                changes.append(Change(range: NSRange(location: contentStart(close), length: end - contentStart(close)), text: ""))
            } else if NSMaxRange(line) > end {
                changes.append(Change(range: line, text: ""))
            } else {
                // The last line of the text: the break before it goes instead of the one after.
                let previous = contentEnd(close - 1)
                changes.append(Change(range: NSRange(location: previous, length: end - previous), text: ""))
            }
        }
        return edit(changes)
    }

    /// Puts `block` on lines of its own below the selection, with blank lines where it would
    /// otherwise join its neighbours. The caret goes to (line, offset) of the block, or with nil to
    /// a new line below it.
    func inserting(_ block: [String], caret: (line: Int, offset: Int)?) -> TextEdit? {
        let index = lines.upperBound
        guard !isCode(index), !isTable(index) else { return nil }
        let end = contentEnd(index), prefix = continuation(index), newline = newline
        let blank = prefix.trimmingTrailingBlanks
        let lineBreak = newline + prefix
        var lead = ""
        if !isEmpty(index) {
            lead = newline + blank + lineBreak
        } else if index > 0, !isEmpty(index - 1) {
            lead = lineBreak
        }
        var result = lead + block.joined(separator: lineBreak)
        var position = end + (result as NSString).length
        if let caret {
            let before = block[..<caret.line].joined(separator: lineBreak) + (caret.line > 0 ? lineBreak : "")
            position = end + ((lead + before) as NSString).length + caret.offset
            if index + 1 < map.lines.count, !isEmpty(index + 1) { result += newline + blank }
        } else {
            result += lineBreak
            position += (lineBreak as NSString).length
        }
        return TextEdit(range: NSRange(location: end, length: 0), replacement: result, selection: NSRange(location: position, length: 0))
    }
}
