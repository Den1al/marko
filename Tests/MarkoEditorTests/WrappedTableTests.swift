import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// A table too wide for single lines: its cells' text wraps in a grid (TableWrap.swift), as
    /// laid out, drawn and edited in a real window.
    @Suite struct WrappedTableTests {
        private let theme = Theme.standard

        private static let long = "Everything a new engineer needs in the first two weeks: laptop setup, access requests, the reading list, "
            + "the buddy programme and the first small change shipped to production."

        private let sample = """
            intro line

            | Area | Owner | What it covers | Notes |
            |:-----|------:|----------------|:-----:|
            | Onboarding | Platform | \(long) | Laptop<br>Reading list for week one<br/> Buddy |
            | **Bold** start | x | `code` first, then a [link](http://example.org/a) and \(long) | c |
            | short |  | Short cell. | last<BR />one |

            end
            """

        /// An editor on `source` with the caret parked at the very end, away from everything.
        private func window(_ source: String, size: NSSize = NSSize(width: 900, height: 700)) -> EditorWindow {
            let w = EditorWindow(source, size: size)
            w.select(w.length)
            w.pump()
            return w
        }

        private func map(_ w: EditorWindow) -> StyleMap { MarkdownStyler.style(w.textView.string) }

        /// The row's part of the grid, with its edges from the text container's left edge, as carets and clicks are.
        private func row(_ w: EditorWindow, at offset: Int) -> TableRow? {
            guard var row = w.displayAttributes(at: offset)[.tableRow] as? TableRow else { return nil }
            row.edges = row.edges.map { $0 + w.columnOrigin }
            return row
        }

        /// The window as drawn, by a place in the text container's coordinates.
        private func drawn(_ w: EditorWindow) -> (isBackground: (CGFloat, CGFloat) -> Bool, color: (CGFloat, CGFloat) -> NSColor) {
            let pixels = w.pixels(), origin = w.columnOrigin
            return ({ pixels.isBackground($0 - origin, $1) }, { pixels.color($0 - origin, $1) })
        }

        /// The width of the page between its paddings, which is the room a table has.
        private func pageWidth(_ w: EditorWindow) -> CGFloat { w.textView.frame.width - 2 * theme.pagePadding.width }

        /// The lines of the first table that are rows, with their place in the map.
        private func rows(_ w: EditorWindow) -> [(index: Int, line: LineStyle)] {
            let map = map(w)
            guard let table = map.tables.first else { return [] }
            return table.lines.filter { $0 != table.lines.lowerBound + 1 }.map { ($0, map.lines[$0]) }
        }

        /// The row's box, in the text container's coordinates.
        private func box(_ w: EditorWindow, ofRowAt offset: Int) -> CGRect {
            w.inColumn((w.fragment(at: offset) as! BlockFragment).tableRowRect!, ofFragmentAt: offset)
                .offsetBy(dx: w.columnOrigin, dy: 0)
        }

        /// The distinct lines that the carets of a cell's text stand on, by their top edge.
        private func lineTops(_ w: EditorWindow, _ cell: TableCell) -> [CGFloat] {
            Set((cell.contentRange.location...NSMaxRange(cell.contentRange)).map { w.caretRect(at: $0).minY.rounded() }).sorted()
        }

        /// What a click at the caret's place at `offset` does.
        private func click(_ w: EditorWindow, at offset: Int) {
            let rect = w.caretRect(at: offset), origin = w.textView.textContainerOrigin
            w.placeCaret(at: NSPoint(x: rect.minX + origin.x + 0.2, y: rect.midY + origin.y))
        }

        /// Every caret stop from `from` on, as the key bound to `command` finds them, up to `limit`.
        private func walk(_ w: EditorWindow, from: Int, _ command: Selector, until end: Int) -> [Int] {
            w.select(from)
            var stops = [w.textView.selectedRange().location]
            for _ in 0..<5000 where stops.last != end {
                w.command(command)
                let now = w.textView.selectedRange().location
                if now == stops.last { break }
                stops.append(now)
            }
            return stops
        }

        /// A real key event for an arrow key through the window.
        private func press(_ w: EditorWindow, arrow: Int, _ flags: NSEvent.ModifierFlags = []) {
            let character = String(UnicodeScalar(arrow)!)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                w.window.sendEvent(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags.union([.numericPad, .function]), timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                    keyCode: [NSUpArrowFunctionKey: 126, NSDownArrowFunctionKey: 125, NSLeftArrowFunctionKey: 123, NSRightArrowFunctionKey: 124][arrow]!)!)
            }
            w.pump(0.005)
        }

        private static let sentence = "a sentence that is long enough to wrap in its cell more than once when the window is not wide at all"

        /// The offsets at which the lines of a cell's text start, as the caret shows them.
        private func lineStarts(_ w: EditorWindow, _ cell: TableCell) -> [Int] {
            var starts: [Int] = [], top = -CGFloat.infinity
            for offset in cell.contentRange.location...NSMaxRange(cell.contentRange) where w.caretRect(at: offset).minY > top + 1 {
                top = w.caretRect(at: offset).minY
                starts.append(offset)
            }
            return starts
        }

        // MARK: geometry

        @Test func everyCellsLinesStandInItsColumnAndARowIsAsHighAsItsTallestCell() throws {
            let w = window(sample)
            defer { w.close() }
            let padding = theme.tableCellPadding, rows = rows(w)
            let edges = try #require(row(w, at: rows[0].line.range.location)).edges
            #expect(edges.count == 5 && edges[0] >= 0 && edges.last! <= pageWidth(w) && edges.last! - edges[0] > pageWidth(w) - 8, "the grid is as wide as the page")
            var below = box(w, ofRowAt: rows[0].line.range.location).minY
            for (_, line) in rows {
                let grid = try #require(row(w, at: line.range.location))
                #expect(grid.edges == edges && grid.cellStarts.count == line.cells.count, "the columns are the same in every row")
                let box = box(w, ofRowAt: line.range.location)
                #expect(abs(box.minY - below) < 0.5 && abs(box.minX - edges[0]) < 0.01 && abs(box.maxX - edges[4]) < 0.01, "rows meet")
                below = box.maxY
                var most = 0
                for (column, cell) in line.cells.enumerated() {
                    let tops = lineTops(w, cell)
                    most = max(most, tops.count)
                    #expect(abs(tops[0] - box.minY - padding.height) < 0.5, "a cell's first line stands below the row's padding")
                    #expect(zip(tops, tops.dropFirst()).allSatisfy { abs($1 - $0 - theme.bodyLineHeight) < 0.5 }, "its lines follow one another")
                    // The blanks of an empty cell that is aligned right or centred hang into its padding.
                    let slack = cell.contentRange.length == 0 ? padding.width : 0
                    for offset in cell.contentRange.location...NSMaxRange(cell.contentRange) {
                        let caret = w.caretRect(at: offset)
                        #expect(caret.minX >= edges[column] + padding.width - 0.5 && caret.maxX <= edges[column + 1] - padding.width + slack + 0.5
                            && caret.maxY <= box.maxY - padding.height + 0.5 && caret.height == theme.bodyLineHeight, "\(offset) in column \(column): \(caret)")
                    }
                }
                #expect(abs(box.height - CGFloat(most) * theme.bodyLineHeight - 2 * padding.height) < 0.5, "as high as the cell with the most lines")
                #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true)
            }
            #expect(lineTops(w, rows[1].line.cells[2]).count > 3 && lineTops(w, rows[1].line.cells[0]).count == 1)
            // The table's rows and nothing else between the lines around it.
            let end = w.fragment(at: w.offset(of: "\nend")).layoutFragmentFrame
            #expect(abs(end.minY - below - theme.tableMargin) < 0.5)
            #expect(w.textView.string == sample && w.storageProblem == nil && w.textView.textLayoutManager != nil)
        }

        @Test func columnsAreAlignedAsTheDelimiterRowSays() throws {
            let w = window(sample)
            defer { w.close() }
            let padding = theme.tableCellPadding.width, blank = " ".size(withAttributes: [.font: theme.bodyFont]).width
            for (_, line) in rows(w) {
                let edges = try #require(row(w, at: line.range.location)).edges
                for (column, cell) in line.cells.enumerated() where cell.contentRange.length > 0 {
                    let left = w.caretRect(at: cell.contentRange.location).minX
                    let tops = lineTops(w, cell), last = w.caretRect(at: NSMaxRange(cell.contentRange))
                    switch column {
                    case 0, 2: #expect(abs(left - edges[column] - padding) < 0.5, "left: \(column)")
                    // The blank before the pipe counts as text, as it does in a grid of single lines.
                    case 1: #expect(abs(last.maxX - (edges[column + 1] - padding)) < blank + 0.5, "right: \(last)")
                    default:
                        guard tops.count == 1 else { continue }
                        #expect(abs((left + last.maxX) / 2 - (edges[column] + edges[column + 1]) / 2) < blank / 2 + 0.5, "centre: \(left) \(last)")
                    }
                }
            }
        }

        @Test func columnsThatFitKeepTheirWidthAndTheLongOnesShareTheRest() {
            func share(_ natural: [CGFloat], _ least: [CGFloat], _ room: CGFloat, held: [CGFloat]? = nil) -> [CGFloat] {
                ParagraphRenderer.wrappedWidths(natural: natural, least: least, held: held ?? natural, room: room)
            }
            // Two short columns keep their widths; two long ones get their least and share the rest by what they hold beyond it.
            #expect(share([40, 60, 1000, 3000], [40, 60, 80, 80], 700) == [40, 60, 185, 414])
            // A column is never narrower than its longest word while the room allows.
            #expect(share([40, 400, 9000], [40, 150, 80], 500) == [40, 156, 303])
            // A column of middling width that an even split has room for keeps it.
            #expect(share([200, 200, 5000], [50, 50, 50], 900) == [200, 200, 500])
            // Everything fits: nothing is stretched.
            #expect(share([100, 200], [50, 60], 500) == [100, 200])
            // Not even the least fits: the columns that need the most give way, down to one width.
            #expect(share([900, 900, 900], [300, 300, 600], 600) == [200, 200, 200])
            #expect(share([60, 900, 900, 70], [60, 300, 600, 70], 500) == [60, 185, 185, 70])
            // A column of many short lines holds as much as one of a long sentence and gets as much,
            // but never more than its longest line needs.
            #expect(share([300, 1200], [80, 80], 600, held: [1200, 1200]) == [300, 300])
            #expect(share([400, 1200], [80, 80], 600, held: [1200, 1200]) == [300, 300])
            #expect(share([250, 1200], [80, 80], 600, held: [1200, 1200]) == [250, 350])
        }

        @Test func aTableNarrowerThanItsLongestWordsStillShowsAsAGridAndWordsBreak() throws {
            let source = "| Identifier | Explanation |\n|---|---|\n| supercalifragilisticexpialidocious_identifier | pneumonoultramicroscopicsilicovolcanoconiosis and more |\n\nend"
            let w = window(source, size: NSSize(width: 330, height: 600))
            defer { w.close() }
            let body = w.offset(of: "| super"), grid = try #require(row(w, at: body))
            #expect(grid.cellStarts.count == 2 && grid.edges.last! <= w.textView.textContainer!.size.width + 0.5)
            let cell = map(w).lines[2].cells[0]
            #expect(lineTops(w, cell).count > 1, "the word is broken")
            for offset in cell.contentRange.location...NSMaxRange(cell.contentRange) {
                #expect(w.caretRect(at: offset).maxX <= grid.edges[1] - theme.tableCellPadding.width + 0.5)
            }
            #expect((w.fragment(at: body) as? BlockFragment)?.fitsItsCells == true)
        }

        /// The renderer counts each cell's lines itself to know which cell is the tallest; the
        /// text system must come to the same lines for whatever the cells hold.
        @Test func rowsFitTheirCellsWhateverTheyHold() {
            var state: UInt64 = 0x2545F4914F6CDD1D
            func random(_ bound: Int) -> Int {
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return Int(state % UInt64(bound))
            }
            let words = ["a", "of", "the", "table", "wrapping", "cells", "**bold**", "*em*", "`code`", "[link](http://example.org/x)", "incident,", "review;",
                         "counter-intuitive", "東京都", "naïve", "1,234.50", "re-read", "x/y/z", "~~gone~~", "<br>", "<br>- item", "\\|", "end."]
            func cell() -> String { (0..<random(40)).map { _ in words[random(words.count)] }.joined(separator: " ") }
            for round in 0..<30 {
                let columns = 2 + random(4)
                let table = (0..<6).map { row in "| " + (0..<columns).map { _ in row == 0 ? "Head" : cell() }.joined(separator: " | ") + " |" }
                let source = "intro\n\n" + ([table[0], "|" + String(repeating: "---|", count: columns)] + table.dropFirst()).joined(separator: "\n") + "\n\nend"
                let w = window(source, size: NSSize(width: CGFloat(360 + random(700)), height: 600))
                defer { w.close() }
                for (_, line) in rows(w) where row(w, at: line.range.location)?.cellStarts.isEmpty == false {
                    #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true, "round \(round): \(w.textView.string.debugDescription) at \(line.range)")
                }
            }
        }

        /// Where the text system breaks a cell into other lines than were counted (seen in
        /// columns too narrow for their words), the row is rendered again with the lines it has.
        @Test func aRowThatIsBrokenIntoOtherLinesThanCountedIsRenderedAgainWithItsLines() throws {
            // Five columns of 57 points: words break wherever the line is full.
            let row = [
                "x/y/z <br> a cells <br> table end. a *em* table counter-intuitive incident, end. cells a incident, 1,234.50 ~~gone~~",
                "re-read 1,234.50 1,234.50 **bold** naïve [link](http://example.org/x) <br>- item <br> incident, <br> \\| re-read 東京都 end. 東京都 counter-intuitive",
                "<br> end.",
                "incident, \\| counter-intuitive re-read of re-read <br>- item wrapping x/y/z `code` **bold** review; <br>- item of <br>- item 東京都 \\| a `code` table end. `code` end. cells [link](http://example.org/x) end. 東京都 re-read \\| <br> *em* re-read",
                "of x/y/z <br> a 1,234.50 review; counter-intuitive table table table counter-intuitive 東京都 the incident, counter-intuitive **bold** <br> incident, naïve naïve re-read **bold** counter-intuitive <br> [link](http://example.org/x) table x/y/z of [link](http://example.org/x) *em* *em* end. the wrapping naïve \\| naïve",
            ].joined(separator: " | ")
            let w = window("| Head | Head | Head | Head | Head |\n|---|---|---|---|---|\n| \(row) |\n\nend", size: NSSize(width: 377, height: 600))
            defer { w.close() }
            let body = w.offset(of: "| x/y/z")
            func laidOut() -> BlockFragment? {
                w.layout.ensureLayout(for: w.layout.documentRange)
                return w.layout.textLayoutFragment(for: w.content.location(w.content.documentRange.location, offsetBy: body)!) as? BlockFragment
            }
            // The window has it right by now. Without what it learned, the count is off again.
            #expect(laidOut()?.fitsItsCells == true)
            // (A change of the zoom forgets everything measured.)
            defer { Theme.zoom = 1 }
            Theme.zoom = 1.25
            Theme.zoom = 1
            let counted = try #require(laidOut())
            try #require(counted.cellLineCounts != counted.wrappedRow?.lineCounts, "the typesetter and the text system agree on this row now: find another")
            #expect(!counted.fitsItsCells)
            #expect(w.editor.refit(in: w.layout.documentRange))
            let again = try #require(laidOut())
            #expect(again.cellLineCounts == again.wrappedRow?.lineCounts && again.fitsItsCells)
            #expect(!w.editor.refit(in: w.layout.documentRange), "and is left alone from then on")
            #expect(w.storageProblem == nil)
        }

        /// A blank and the hidden closing pipe behind a word that fills its cell's line stay on that line.
        @Test func theClosingPipeBehindAFullLineIsNoLineOfItsOwn() throws {
            let rows = (1...3).map { "| \($0) | item \($0) of the store room | `c\($0)` |\n" }.joined()
            let w = window("| No | Item | Code |\n|---:|:---|:---:|\n" + rows + "\nend\n", size: NSSize(width: 320, height: 600))
            defer { w.close() }
            let header = try #require(w.fragment(at: 0) as? BlockFragment), row = try #require(header.wrappedRow)
            #expect(row.lineCounts == [1, 1, 1] && header.cellLineCounts == [1, 1, 1] && header.fitsItsCells)
        }

        // MARK: a long table

        private static func longTable(_ count: Int) -> String {
            "| Id | What | Checks | Notes |\n|---|---|---|---|\n" + (1...count).map {
                "| \($0) | Row \($0): \(long) | first check<br>second check<br>check \($0) | A note of some length that wraps in its cell too. |\n"
            }.joined()
        }

        /// The row at the top of the window, by its number.
        private func topRow(_ w: EditorWindow) -> Int {
            let top = w.editor.place.top?.offset ?? 0
            return Int((w.textView.string as NSString).substring(from: top).dropFirst(2).prefix { $0.isNumber }) ?? 0
        }

        /// One window further down, as a frame of scrolling does it.
        private func page(_ w: EditorWindow) {
            let clip = w.editor.scrollView.contentView
            clip.scroll(to: clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: clip.bounds.height)).origin)
            w.editor.scrollView.reflectScrolledClipView(clip)
            w.window.layoutIfNeeded()
            w.pump(0.01)
        }

        /// TextKit guesses the height of rows that are not laid out; the scroller's knob and the
        /// height of the page go by that. The guess is the row's height (see `wrapCells`).
        @Test func theScrollerGoesByTheRowsOfALongTableOfWrappingCells() throws {
            let w = EditorWindow(Self.longTable(300))
            defer { w.close() }
            let clip = w.editor.scrollView.contentView, scroller = try #require(w.editor.scrollView.verticalScroller)
            var heights = [w.textView.frame.height], off: [String] = []
            for _ in 0..<200 where clip.bounds.maxY < w.textView.frame.height - 1 {
                page(w)
                heights.append(w.textView.frame.height)
                // The knob is where the window's top is in the text; the rows are all about as high.
                let row = topRow(w), expected = Double(row - 1) / 295
                if abs(scroller.doubleValue - expected) > 0.02 { off.append("row \(row): \(scroller.doubleValue)") }
            }
            #expect(heights.count > 40, "the table is many windows long")
            #expect(off.isEmpty, "the knob is not where the rows are: \(off)")
            let real = try #require(heights.last)
            #expect(heights.allSatisfy { abs($0 - real) < real * 0.02 }, "the page changes its height while it is scrolled: \(heights.min()!) to \(heights.max()!), really \(real)")
            #expect((w.layout.textLayoutFragment(for: CGPoint(x: 1, y: clip.bounds.midY)) as? BlockFragment)?.wrappedRow?.cellStarts.count == 4)
        }

        /// A file that is opened again comes back at the row it was left at, also where the text
        /// above the table makes TextKit guess the rows' heights several times too high.
        @Test func aPlaceDeepInALongTableOfWrappingCellsIsRestored() throws {
            for head in ["# Title\n\n", (1...60).map { "Short line \($0).\n\n" }.joined()] {
                let text = head + Self.longTable(300)
                let w = EditorWindow(text)
                defer { w.close() }
                for row in [150, 290, 40] {
                    w.select(w.offset(of: "| \(row) | Row"))
                    w.editor.scrollToSelection()
                    page(w)
                    let place = w.editor.place, top = topRow(w)
                    #expect(abs(top - row) < 12, "the window is near row \(row): \(top)")
                    // As a file shown again: the text anew, then its place.
                    w.editor.text = text
                    w.editor.place = place
                    #expect(topRow(w) == top && w.editor.place.top?.offset == place.top?.offset, "row \(top) is at the top again: \(topRow(w))")
                    #expect(abs((w.editor.place.top?.past ?? 0) - (place.top?.past ?? 99)) < 1)
                    w.pump()
                    #expect(topRow(w) == top, "and stays there once the page has settled")
                }
            }
        }

        @Test func theHeaderRowOnAListItemsMarkerLineIsAsHighAsItsCells() {
            // The first cell's first line is longer by the marker that hangs in front of it.
            let rest = "second cell with words enough to take two lines of its column here | third cell is the long one of the row, with a lot of words that go on "
                + "and on so that the table has to wrap its cells in any window |\n  |---|---|---|\n  | a | b | c |\n\nend"
            for (marker, indent, lengths) in [("- ", 2, [1, 3, 6, 7]), ("1. ", 3, [3]), ("- [ ] ", 2, [1, 6])] {
                for letters in lengths {
                    for words in stride(from: 0, through: 34, by: 3) {
                        let first = "first " + String(repeating: "i", count: letters) + String(repeating: " ab", count: words)
                        let w = window("\(marker)| \(first) | \(rest.replacingOccurrences(of: "\n  ", with: "\n" + String(repeating: " ", count: indent)))", size: NSSize(width: 900, height: 500))
                        defer { w.close() }
                        let header = w.fragment(at: 0) as? BlockFragment
                        #expect(header?.wrappedRow != nil && header?.fitsItsCells == true, "\(marker.debugDescription) \(letters) \(words)")
                    }
                }
            }
        }

        @Test func aTableWithMoreColumnsThanFitTheTextColumnShowsAsSource() throws {
            func source(_ columns: Int) -> String {
                "before\n\n|" + (0..<columns).map { " column number \($0) with words |" }.joined() + "\n|" + String(repeating: "---|", count: columns)
                    + "\n|" + (0..<columns).map { " cell \($0) with some more words in it |" }.joined() + "\n\nafter\n"
            }
            let least = theme.tableMinimumCellWidth + 2 * theme.tableCellPadding.width
            for (width, height) in [(900, 700), (420, 900)] {
                let probe = window("x", size: NSSize(width: width, height: height))
                let fitting = Int(pageWidth(probe) / least)
                probe.close()
                // As many columns as fit at the least width: still a grid, on the page, its rows as high as their cells.
                let most = window(source(fitting), size: NSSize(width: width, height: height))
                defer { most.close() }
                let header = most.offset(of: "| column"), grid = try #require(row(most, at: header))
                #expect(grid.cellStarts.count == fitting && grid.edges[0] >= 0 && grid.edges.last! <= pageWidth(most), "\(width): \(grid.edges)")
                #expect(zip(grid.edges, grid.edges.dropFirst()).allSatisfy { $1 - $0 >= least })
                for (_, line) in rows(most) { #expect((most.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true) }
                // One more: its source, set like code, and nothing drawn beyond the text column.
                for columns in [fitting + 1, fitting + 4] {
                    let w = window(source(columns), size: NSSize(width: width, height: height))
                    defer { w.close() }
                    #expect(row(w, at: header) == nil && w.displayAttributes(at: header)[.codePanel] != nil, "\(width), \(columns) columns")
                    #expect(w.fragment(at: header).textLineFragments.allSatisfy { $0.typographicBounds.maxX <= w.columnOrigin + w.textView.columnWidth + 0.5 })
                    #expect(w.textView.string == source(columns) && w.storageProblem == nil)
                }
            }
        }

        @Test func wordsBreakOnlyInTheColumnsThatCannotAvoidIt() throws {
            let source = """
                | Name | Owner | Status | Notes on it | Due |
                |---|:---:|---:|---|---|
                | Parser rewrite | Ada | 80% | Waiting for the review of the inline pass | Friday |
                | Sidebar drag | Lin | 100% | Shipped, *needs* a real pointer check | Monday |
                | Wrapped tables | Sam | 45% | `GridLayoutManager` and the row fragment | next week |

                end
                """
            let w = window(source, size: NSSize(width: 500, height: 900))
            defer { w.close() }
            let text = w.textView.string as NSString
            #expect(try #require(row(w, at: 0)).cellStarts.count == 5)
            // No word but the one that is wider than its column is on two lines.
            for (_, line) in rows(w) {
                for cell in line.cells {
                    text.enumerateSubstrings(in: cell.contentRange, options: [.byWords, .substringNotRequired]) { _, word, _, _ in
                        guard text.substring(with: word) != "GridLayoutManager" else { return }
                        #expect(w.caretRect(at: word.location).minY == w.caretRect(at: NSMaxRange(word)).minY, "\(text.substring(with: word))")
                    }
                }
                #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true)
            }
        }

        @Test func aWordWithAnEmojiIsMeasuredWhole() throws {
            let word = "release🎉notes🎉final🎉draft"
            let w = window("| A | B |\n|---|---|\n| \(word) | \(Self.long) \(Self.long) |\n\nend", size: NSSize(width: 600, height: 600))
            defer { w.close() }
            let cell = rows(w)[1].line.cells[0]
            #expect(try #require(row(w, at: 0)).cellStarts.count == 2 && lineTops(w, cell).count == 1, "the column is as wide as the word")
        }

        @Test func everyKindOfGridKeepsToThePage() throws {
            // A window with room beside the text column, and tables of every width around the column's and the page's.
            var compact = 0, beside = 0, wrapping = 0
            for words in 16...34 {
                let cells = "| Phase | " + (0..<words).map { "word\($0 % 10)" }.joined(separator: " ") + " |"
                let w = window("- item\n\n  | A | B |\n  |---|---|\n  \(cells)\n\n| A | B |\n|---|---|\n\(cells)\n\nend", size: NSSize(width: 1000, height: 500))
                defer { w.close() }
                #expect(w.textView.textContainer!.size.width > w.textView.columnWidth + 40)
                for (number, table) in map(w).tables.enumerated() {
                    let body = map(w).lines[table.lines.upperBound - 1], grid = try #require(row(w, at: body.range.location))
                    let isCompact = w.displayFont(at: body.cells[0].contentRange.location).pointSize == theme.compactTableSize
                    // From the page's left edge, or the indent of the list it is in, to the page's right edge at most.
                    let least = number == 0 ? w.columnOrigin + theme.listIndent : 0
                    #expect(grid.edges[0] >= least && grid.edges.last! <= pageWidth(w), "\(words) words: \(grid.edges)")
                    // One that is wider than the column stands in the middle of the page.
                    if number == 1, grid.edges.last! - grid.edges[0] > w.textView.columnWidth { #expect(abs(grid.edges[0] + grid.edges.last! - pageWidth(w)) <= 1) }
                    compact += isCompact ? 1 : 0
                    beside += grid.edges.last! > w.columnOrigin + w.textView.columnWidth ? 1 : 0
                    wrapping += grid.cellStarts.isEmpty ? 0 : 1
                }
            }
            #expect(compact > 0 && beside > 0 && wrapping > 0)
        }

        @Test func theGridIsDrawnWithHairlinesAHeaderFillStripesAndRoundedCorners() throws {
            let w = window(sample)
            defer { w.close() }
            let pixels = drawn(w), rows = rows(w)
            let header = box(w, ofRowAt: rows[0].line.range.location), first = box(w, ofRowAt: rows[1].line.range.location)
            let second = box(w, ofRowAt: rows[2].line.range.location), last = box(w, ofRowAt: rows[3].line.range.location)
            let edges = try #require(row(w, at: rows[0].line.range.location)).edges
            func isLine(_ x: CGFloat, _ y: CGFloat, across: CGVector = CGVector(dx: 6, dy: 0)) -> Bool {
                !pixels.isBackground(x, y) && pixels.color(x, y) != pixels.color(x + across.dx, y + across.dy)
            }
            for edge in edges.dropLast() { #expect(isLine(edge + 0.5, first.midY + 20), "a rule at \(edge)") }
            #expect(isLine(edges[4] - 0.5, first.midY))
            let down = CGVector(dx: 0, dy: -4)
            #expect(isLine(edges[2] + 40, first.minY - 0.5, across: down) && isLine(edges[2] + 40, second.minY - 0.5, across: down)
                && isLine(edges[2] + 40, last.maxY - 0.5, across: down), "rules between rows and under the last")
            #expect(!pixels.isBackground(edges[1] - 6, header.midY) && pixels.isBackground(edges[1] - 6, first.maxY - 3), "the header is filled, a plain row is not")
            #expect(!pixels.isBackground(edges[1] - 6, second.maxY - 3), "every other row is striped")
            #expect(pixels.isBackground(edges[0] + 0.5, header.minY + 0.5) && pixels.isBackground(edges[4] - 0.5, last.maxY - 0.5), "the outer corners are rounded")
            // The text is where the caret says it is: ink right of the caret before a letter, in every column.
            for word in ["Onboarding", "Platform", "Everything", "Laptop", "Reading", "Short"] {
                let caret = w.caretRect(at: w.offset(of: word))
                let ink = stride(from: caret.minY + 4, to: caret.maxY - 4, by: 1).contains { y in
                    stride(from: caret.minX + 1, to: caret.minX + 9, by: 0.5).contains { x in !pixels.isBackground(x, y) && pixels.color(x, y).brightnessComponent < 0.5 }
                }
                #expect(ink, "\(word) is drawn at \(caret)")
            }
        }

        @Test func atAnotherZoomTheColumnsAreMeasuredAnewAndTheRowsStillFit() throws {
            defer { Theme.zoom = 1 }
            let w = window(sample)
            defer { w.close() }
            let header = w.offset(of: "| Area"), before = try #require(row(w, at: header)).edges
            Theme.zoom = 1.5
            w.pump()
            let zoomed = try #require(row(w, at: header))
            #expect(zoomed.cellStarts.count == 4 && zoomed.edges != before && zoomed.edges.last! <= w.textView.columnWidth)
            for (_, line) in rows(w) {
                #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true)
                let caret = w.caretRect(at: line.cells[0].contentRange.location)
                #expect(caret.height == theme.bodyLineHeight && abs(caret.minX - zoomed.edges[0] - theme.tableCellPadding.width) < 0.5)
            }
            #expect(w.textView.string == sample && w.storageProblem == nil)
        }

        @Test func tablesInQuotesAndListsWrapAtTheirIndent() throws {
            let cells = "| Phase | \(Self.long) | Checks |"
            let source = "> | A | B | C |\n> |---|---|---|\n> \(cells)\n\n- item\n\n  | A | B | C |\n  |---|---|---|\n  \(cells)\n\n- | A | B | C |\n  |---|---|---|\n  \(cells)\n\nend"
            let w = window(source)
            defer { w.close() }
            let map = map(w)
            #expect(map.tables.count == 3)
            for (table, indent) in zip(map.tables, [theme.quoteIndent, theme.listIndent, theme.listIndent]) {
                for index in table.lines where index != table.lines.lowerBound + 1 {
                    let line = map.lines[index], grid = try #require(row(w, at: line.range.location))
                    #expect(grid.cellStarts.count == 3 && abs(grid.edges[0] - w.columnOrigin - indent) < 0.5 && grid.edges.last! <= w.textView.textContainer!.size.width)
                    #expect(abs(w.caretRect(at: line.cells[0].contentRange.location).minX - w.columnOrigin - indent - theme.tableCellPadding.width) < 0.5)
                    #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true)
                }
            }
            // The marker of the item that the last table starts hangs in front of the grid.
            let marked = try #require(w.fragment(at: map.lines[map.tables[2].lines.lowerBound].range.location) as? BlockFragment)
            let bullet = try #require(marked.bullets.first?.rect), frame = marked.layoutFragmentFrame
            #expect(bullet.maxX + frame.minX <= w.columnOrigin + theme.listIndent + theme.tableCellPadding.width && bullet.minY > 0 && bullet.maxY < theme.bodyLineHeight + theme.tableMargin + theme.tableCellPadding.height)
            #expect(w.textView.string == source && w.storageProblem == nil)
        }

        @Test func aTableThatEndsTheTextHasItsLastRowWholeAndTheCaretBelowIt() throws {
            let table = "| A | B |\n|---|---|\n| \(Self.long) \(Self.long) | short |"
            for end in ["", "\n", "\r\n"] {
                let w = window(table.replacingOccurrences(of: "\n", with: end.isEmpty ? "\n" : end) + end, size: NSSize(width: 500, height: 600))
                defer { w.close() }
                let body = w.offset(of: "| Every"), box = box(w, ofRowAt: body)
                #expect(row(w, at: body)?.cellStarts.count == 2 && (w.fragment(at: body) as? BlockFragment)?.fitsItsCells == true, "\(end.debugDescription)")
                #expect(w.caretRect(at: w.offset(of: "short")).minY < box.minY + theme.bodyLineHeight)
                w.select(w.length)
                let caret = w.caretRect(at: w.textView.selectedRange().location)
                if end.isEmpty {
                    #expect(w.textView.selectedRange().location == w.length - 1 && caret.maxY <= box.maxY && caret.minX > w.caretRect(at: w.offset(of: "short")).minX + 20,
                            "in front of the closing pipe, behind the cell's text: \(caret)")
                } else {
                    #expect(w.textView.selectedRange().location == w.length && caret.minY >= box.maxY - 0.5 && caret.minX < 1, "on the line below the table: \(caret)")
                }
            }
        }

        @Test func aClickOnTheEmptyLineBelowATableThatEndsTheTextPutsTheCaretThere() {
            let w = window("before\n\n| Name | Text | More |\n|---|---|---|\n| one | \(Self.sentence) | \(Self.sentence) |\n| two | x | y |\n")
            defer { w.close() }
            #expect(row(w, at: w.offset(of: "| two"))?.cellStarts.count == 3)
            let rect = w.caretRect(at: w.length), origin = w.textView.textContainerOrigin
            let found = w.layout.textSelectionNavigation.textSelections(
                interactingAt: CGPoint(x: rect.minX + 0.2, y: rect.midY), inContainerAt: w.layout.documentRange.location,
                anchors: [], modifiers: [], selecting: false, bounds: .zero)
            #expect(found.first?.textRanges.first.map { w.content.offset(from: w.content.documentRange.location, to: $0.location) } == w.length)
            w.select(0)
            w.placeCaret(at: NSPoint(x: rect.minX + origin.x + 0.2, y: rect.midY + origin.y))
            #expect(w.textView.selectedRange() == NSRange(location: w.length, length: 0))
            // And one in the last row is in the row.
            click(w, at: w.offset(of: "x |"))
            #expect(w.textView.selectedRange().location == w.offset(of: "x |"))
        }

        // MARK: what shows in a cell

        @Test func aBreakTagThatASelectionOnlyCoversStaysALineBreak() throws {
            let w = window(sample)
            defer { w.close() }
            let notes = w.offset(of: "Laptop"), first = w.offset(of: "<br>"), cell = rows(w)[1].line.cells[3]
            let tops = lineTops(w, cell), height = w.fragment(at: notes).layoutFragmentFrame.height
            func isBreak() -> Bool { (w.displayParagraph(at: first).text.string as NSString).character(at: w.displayParagraph(at: first).index) == 0x2028 }
            // Everything selected, and a selection from the cell before into the row below.
            for selection in [NSRange(location: 0, length: w.length), NSRange(location: w.offset(of: "buddy programme"), length: w.offset(of: "start |") - w.offset(of: "buddy programme"))] {
                w.select(selection.location, length: selection.length)
                w.pump()
                #expect(isBreak() && lineTops(w, cell) == tops && w.fragment(at: notes).layoutFragmentFrame.height == height, "\(selection)")
            }
            // An end of the selection at the tag shows it, like the caret.
            for selection in [NSRange(location: notes, length: first - notes), NSRange(location: first + 2, length: 9)] {
                w.select(selection.location, length: selection.length)
                w.pump()
                #expect(!isBreak(), "\(selection)")
            }
            w.select(notes, length: first + 6 - notes)
            w.pump()
            #expect(isBreak(), "and is a break again when the selection's end has passed it")
            #expect(w.textView.string == sample)
        }

        @Test func aBreakTagIsALineBreakInItsCellAndShowsWhenTheCaretTouchesIt() throws {
            let w = window(sample)
            defer { w.close() }
            let notes = w.offset(of: "Laptop"), first = w.offset(of: "<br>"), second = w.offset(of: "<br/>"), third = w.offset(of: "<BR />")
            for (tag, length) in [(first, 4), (second, 5), (third, 6)] {
                let (shown, index) = w.displayParagraph(at: tag)
                #expect((shown.string as NSString).substring(with: NSRange(location: index, length: length)) == "\u{2028}" + String(repeating: "\u{2060}", count: length - 1))
            }
            // The blank behind a tag does not indent the line it starts.
            #expect((w.displayParagraph(at: second + 5).text.string as NSString).character(at: w.displayParagraph(at: second + 5).index) == 0x2060)
            let lines = [notes, w.offset(of: "Reading"), w.offset(of: "Buddy")].map { w.caretRect(at: $0) }
            #expect(lines[1].minY - lines[0].minY == theme.bodyLineHeight && lines[2].minY > lines[1].minY, "each part on a line of its own")
            let edges = try #require(row(w, at: notes)).edges
            #expect(lines.allSatisfy { $0.minX >= edges[3] && $0.maxX <= edges[4] })
            #expect(abs(lines[2].midX + w.caretRect(at: w.offset(of: "Buddy") + 5).midX - edges[3] - edges[4]) < 6, "the part after the blank is centred like the others")

            // The caret at either end of the tag shows it as the text it is, on the line it ends.
            for touching in [first, first + 4] {
                w.select(touching)
                w.pump()
                let (shown, index) = w.displayParagraph(at: first)
                #expect((shown.string as NSString).substring(with: NSRange(location: index, length: 4)) == "<br>")
                #expect(shown.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor == theme.marker)
                #expect(w.caretRect(at: first + 4).minY == w.caretRect(at: first).minY && w.caretRect(at: first + 4).minX > w.caretRect(at: first).minX + 10)
            }
            w.select(w.length)
            w.pump()
            #expect((w.displayParagraph(at: first).text.string as NSString).character(at: w.displayParagraph(at: first).index) == 0x2028, "and hides it again when it leaves")
            #expect((w.fragment(at: notes) as? BlockFragment)?.fitsItsCells == true)
            // In a code span it is no tag.
            let code = window("| A | B |\n|---|---|\n| `a<br>b` | \(Self.long) \(Self.long) |\n\nend")
            defer { code.close() }
            #expect(row(code, at: 0)?.cellStarts.count == 2 && code.displayParagraph(at: code.offset(of: "<br>")).text.string.contains("a<br>b"))
        }

        @Test func aBreakTagInAGridOfSingleLinesStaysText() {
            let w = window("| A | B |\n|---|---|\n| one<br>two | x |\n\nend")
            defer { w.close() }
            #expect(row(w, at: 0)?.cellStarts == [] && w.displayParagraph(at: 20).text.string.contains("one<br>two"))
        }

        @Test func inlineMarkdownIsRenderedInWrappedCellsAndRevealedOnTouch() throws {
            let w = window(sample)
            defer { w.close() }
            let bold = w.offset(of: "**Bold**"), code = w.offset(of: "`code`"), link = w.offset(of: "[link]")
            #expect(w.displayFont(at: bold + 3).fontDescriptor.symbolicTraits.contains(.bold))
            let (hidden, index) = w.displayParagraph(at: bold)
            #expect((hidden.string as NSString).substring(with: NSRange(location: index, length: 2)) == "\u{200C}\u{200C}", "hidden markers have no width and no size of their own")
            #expect(w.caretRect(at: bold + 2).minX - w.caretRect(at: bold).minX < 0.01)
            #expect(w.displayAttributes(at: code + 2)[.inlineBackground] != nil && w.displayFont(at: code + 2).isFixedPitch)
            #expect(w.displayAttributes(at: link + 2)[.foregroundColor] as? NSColor == theme.link)
            #expect(w.caretRect(at: link + 6).minX - w.caretRect(at: link + 5).minX < 0.01, "the address takes no room")
            // A cell that starts with hidden markers or with code stands on the line of its neighbours.
            #expect(w.caretRect(at: bold + 4).minY == w.caretRect(at: w.offset(of: "x |")).minY && w.caretRect(at: code + 3).minY == w.caretRect(at: bold + 4).minY)
            let edges = try #require(row(w, at: bold)).edges, height = w.fragment(at: bold).layoutFragmentFrame.height

            w.select(bold + 4)
            w.pump()
            let shown = w.displayParagraph(at: bold)
            #expect((shown.text.string as NSString).substring(with: NSRange(location: shown.index, length: 2)) == "**")
            #expect(w.displayAttributes(at: bold)[.foregroundColor] as? NSColor == theme.marker && w.caretRect(at: bold + 2).minX - w.caretRect(at: bold).minX > 5)
            #expect(row(w, at: bold)?.edges == edges, "revealed markers leave the columns where they are")
            w.select(link + 3)
            w.pump()
            #expect(w.caretRect(at: link + 30).minX != w.caretRect(at: link + 7).minX || w.caretRect(at: link + 30).minY != w.caretRect(at: link + 7).minY, "the address shows")
            #expect(row(w, at: bold)?.edges == edges && (w.fragment(at: bold) as? BlockFragment)?.fitsItsCells == true)
            w.select(w.length)
            w.pump()
            #expect(w.fragment(at: bold).layoutFragmentFrame.height == height)
        }

        // MARK: the caret

        @Test func aClickPutsTheCaretWhereItShowsAtEveryOffsetOfTheTable() throws {
            let w = window(sample)
            defer { w.close() }
            let table = NSRange(location: w.offset(of: "| Area"), length: w.offset(of: "\n\nend") - w.offset(of: "| Area"))
            var stops = 0, wrong: [String] = []
            for offset in table.location...NSMaxRange(table) {
                w.select(offset)
                guard w.textView.selectedRange() == NSRange(location: offset, length: 0) else { continue }
                stops += 1
                let rect = w.caretRect(at: offset)
                click(w, at: offset)
                let got = w.textView.selectedRange()
                // Two offsets with nothing visible between them are one place.
                if got != NSRange(location: offset, length: 0), w.caretRect(at: got.location) != rect { wrong.append("\(offset) -> \(got)") }
            }
            #expect(stops > 500 && wrong.isEmpty, "\(wrong)")
            #expect(w.textView.string == sample)
        }

        /// What the text view itself does with a mouse click or drag: it asks the layout manager
        /// for the line under the point and for the caret positions on that line.
        @Test func theTextSystemFindsTheSameOffsetsForAPoint() {
            let w = window(sample)
            defer { w.close() }
            let navigation = w.layout.textSelectionNavigation
            for word in ["Area", "Platform", "Everything", "laptop", "reading list", "production", "Reading", "Buddy", "start", "link", "Short", "one |"] {
                let offset = w.offset(of: word) + 2, rect = w.caretRect(at: offset)
                let found = navigation.textSelections(
                    interactingAt: CGPoint(x: rect.minX + 0.2, y: rect.midY), inContainerAt: w.layout.documentRange.location,
                    anchors: [], modifiers: [], selecting: false, bounds: .zero)
                let location = found.first?.textRanges.first.map { w.content.offset(from: w.content.documentRange.location, to: $0.location) }
                #expect(location == offset, "\(word)")
            }
        }

        @Test func aClickInTheEmptyPartOfACellStaysInThatCell() throws {
            let w = window(sample)
            defer { w.close() }
            let origin = w.textView.textContainerOrigin, onboarding = w.offset(of: "Onboarding")
            let box = box(w, ofRowAt: onboarding), edges = try #require(row(w, at: onboarding)).edges
            // Far below the one line of the first cell: the end of that line, not the long cell beside it.
            w.placeCaret(at: NSPoint(x: origin.x + edges[0] + 30, y: origin.y + box.maxY - 12))
            #expect(w.textView.selectedRange().location > onboarding && w.textView.selectedRange().location <= onboarding + 10)
            // Right of the right-aligned cell's text and left of it: the cell's end and its start.
            w.placeCaret(at: NSPoint(x: origin.x + edges[2] - 2, y: origin.y + box.minY + 12))
            #expect(w.textView.selectedRange().location == w.offset(of: "Platform") + 9)
            w.placeCaret(at: NSPoint(x: origin.x + edges[1] + 2, y: origin.y + box.maxY - 12))
            #expect(w.textView.selectedRange().location == w.offset(of: "Platform"))
            // The empty cell of the last row.
            let short = w.offset(of: "| short")
            w.placeCaret(at: NSPoint(x: origin.x + (edges[1] + edges[2]) / 2, y: origin.y + self.box(w, ofRowAt: short).midY))
            #expect([short + 9, short + 10, short + 11].contains(w.textView.selectedRange().location))
        }

        @Test func leftAndRightVisitEveryPlaceOnceInTheOrderOfTheText() throws {
            let w = window(sample)
            defer { w.close() }
            let start = w.offset(of: "intro line") + 6, end = w.offset(of: "end") + 1, map = map(w), text = w.textView.string as NSString
            let right = walk(w, from: start, #selector(NSResponder.moveRight(_:)), until: end)
            #expect(right.last == end && zip(right, right.dropFirst()).allSatisfy { $0 < $1 })
            let table = try #require(map.tables.first), delimiter = map.lines[table.lines.lowerBound + 1].range
            #expect(!right.contains { NSLocationInRange($0, delimiter) }, "the delimiter row is stepped over")
            // One press, one place: no two stops behind one another show the caret at the same spot.
            w.select(w.length)
            w.pump()
            var same: [Int] = []
            for (before, after) in zip(right, right.dropFirst()) where text.substring(with: NSRange(location: before, length: after - before)).contains("|") {
                if w.caretRect(at: before) == w.caretRect(at: after) { same.append(after) }
            }
            #expect(same.isEmpty, "\(same)")
            // Every cell is passed through from its text's start to its end.
            for index in table.lines where index != table.lines.lowerBound + 1 {
                for cell in map.lines[index].cells where cell.contentRange.length > 0 {
                    #expect(right.contains(cell.contentRange.location) && right.contains(NSMaxRange(cell.contentRange)), "\(cell.contentRange)")
                }
            }
            let left = walk(w, from: end, #selector(NSResponder.moveLeft(_:)), until: start)
            #expect(left.last == start && zip(left, left.dropFirst()).allSatisfy { $0 > $1 })
            #expect(Set(left).symmetricDifference(right).allSatisfy { offset in map.lines[map.lineIndex(containing: offset)!].tokens.contains { NSLocationInRange(offset, $0.range) || NSMaxRange($0.range) == offset } },
                    "the same places both ways, markers that only show from one side apart: \(Set(left).symmetricDifference(right).sorted())")
            #expect(w.textView.string == sample)
        }

        @Test func upAndDownGoThroughACellsLinesThenToTheSameColumnOfTheNextRowAndOutOfTheTable() throws {
            // No markers at the places the caret comes by: one that shows itself there would move the lines.
            let source = """
                a line of text above the table, as wide as the table, so the caret can come from above any column

                | Area | Owner | What it covers | Notes |
                |------|-------|----------------|-------|
                | Onboarding | Platform | \(Self.long) | Laptop and accounts<br>Reading list for week one<br>Buddy |
                | Releases | Delivery | \(Self.long) \(Self.long) | none |
                | Incidents |  | Short cell. | Declare early<br>One channel only |

                a line of text below the table, as wide as the table, so the caret can leave it below any column
                """
            let w = window(source)
            defer { w.close() }
            let edges = try #require(row(w, at: w.offset(of: "| Area"))).edges, rows = rows(w)
            let above = w.offset(of: "a line of text above"), below = w.offset(of: "a line of text below"), table = w.offset(of: "| Area")
            for column in 0..<4 {
                // From the line above the table, two lines up, at a place above the column.
                let x = edges[column] + 40
                let start = try #require((above..<above + 95).first { w.caretRect(at: $0).minX > x })
                w.select(start)
                var tops: [CGFloat] = []
                for _ in 0..<60 {
                    w.command(#selector(NSResponder.moveDown(_:)))
                    let offset = w.textView.selectedRange().location
                    guard offset >= table else { continue }
                    guard offset < below - 1 else { break }
                    let caret = w.caretRect(at: offset)
                    #expect(caret.minX >= edges[column] && caret.maxX <= edges[column + 1], "column \(column): \(offset) at \(caret)")
                    #expect(caret.minY > tops.last ?? 0, "downwards")
                    tops.append(caret.minY)
                }
                // Every line of the column, however the cells beside them are, and through an empty cell.
                let lines = rows.reduce(0) { $0 + lineTops(w, $1.line.cells[column]).count }
                #expect(tops.count == lines, "column \(column): \(tops.count) stops for \(lines) lines")
                // Over the blank line onto the line below the table, below where it started.
                #expect(w.textView.selectedRange().location == below - 1)
                w.command(#selector(NSResponder.moveDown(_:)))
                let left = w.textView.selectedRange().location
                #expect(left >= below && abs(w.caretRect(at: left).minX - w.caretRect(at: start).minX) < 8, "\(left) at \(w.caretRect(at: left))")
                var back = 0
                for _ in 0..<60 {
                    w.command(#selector(NSResponder.moveUp(_:)))
                    let offset = w.textView.selectedRange().location
                    guard offset < below - 1 else { continue }
                    guard offset >= table else { break }
                    let caret = w.caretRect(at: offset)
                    #expect(caret.minX >= edges[column] && caret.maxX <= edges[column + 1], "up in column \(column): \(caret)")
                    back += 1
                }
                #expect(back == lines, "column \(column): \(back) stops up for \(lines) lines")
                w.command(#selector(NSResponder.moveUp(_:)))
                #expect(w.textView.selectedRange().location == start, "and back to where it came from")
            }
            #expect(w.textView.string == source)
        }

        @Test func upAndDownGoThroughHeadingsInATextThatHasAWrappedTable() throws {
            let source = "Para one\n\n## Heading two\n\nAfter heading.\n\n# One\ntext\n\n" + sample
            let w = window(source)
            defer { w.close() }
            #expect(row(w, at: w.offset(of: "| Onboarding"))?.cellStarts.isEmpty == false, "the table wraps")
            let table = w.offset(of: "| Area")
            // The starts of the lines above the table: each of them is one press of the key.
            let lines = [0, 9, 10, 25, 26, 41, 42, 48, 53, 54, 65]
            for column in [0, 4, 8] {
                let down = walk(w, from: column, #selector(NSResponder.moveDown(_:)), until: table - 1)
                #expect(down.map { stop in lines.last { $0 <= stop } } == lines, "down from \(column), a line a press: \(down)")
                let up = walk(w, from: down.last!, #selector(NSResponder.moveUp(_:)), until: column)
                #expect(up == down.reversed(), "up again: \(up)")
            }
            #expect(w.textView.string == source)
        }

        @Test func theCaretNeverRestsAmongWhatIsHiddenInFrontOfACell() {
            let w = window(sample)
            defer { w.close() }
            let platform = w.offset(of: "Platform"), onboarding = w.offset(of: "Onboarding")
            // Behind the pipe and in front of the blank: forwards to the cell's text, backwards to the end of the cell before.
            w.select(platform + 4)
            w.select(platform - 1)
            #expect(w.textView.selectedRange().location == platform - 2)
            w.select(onboarding)
            w.select(platform - 1)
            #expect(w.textView.selectedRange().location == platform)
            w.select(onboarding - 1)
            #expect(w.textView.selectedRange().location == onboarding, "the first cell's blank is hidden with its pipe")
            w.command(#selector(NSResponder.moveLeft(_:)))
            #expect(w.textView.selectedRange().location == w.offset(of: "Notes |") + 6, "leftwards from the row's start is the end of the header row, over the delimiter row")
            // Backspace at the start of a cell's text does nothing, as behind the pipe; nor does Delete in front of one.
            for start in [platform, onboarding] {
                w.select(start)
                w.type(String(EditorWindow.backspace))
                #expect(w.textView.string == sample && w.textView.selectedRange().location == start)
            }
            w.select(platform - 2)
            w.command(#selector(NSResponder.deleteForward(_:)))
            #expect(w.textView.string == sample)
            // An empty cell keeps its blanks as the place for its caret.
            let empty = w.offset(of: "| short |") + 9
            w.select(empty + 1)
            #expect(w.textView.selectedRange().location == empty + 1)
            // A selection takes what is hidden whole.
            w.select(onboarding + 3)
            w.select(onboarding + 3, length: platform - 1 - onboarding - 3)
            #expect(w.textView.selectedRange() == NSRange(location: onboarding + 3, length: platform - onboarding - 3))
        }

        // MARK: selections

        @Test func whatIsSelectedIsHighlightedInItsCellsOnly() throws {
            let w = window(sample)
            defer { w.close() }
            let edges = try #require(row(w, at: w.offset(of: "| Area"))).edges
            let table = CGRect(x: edges[0], y: box(w, ofRowAt: w.offset(of: "| Area")).minY, width: edges[4] - edges[0], height: 0)
                .union(box(w, ofRowAt: w.offset(of: "| short")))
            func segments(_ range: NSRange, _ type: NSTextLayoutManager.SegmentType) -> [CGRect] {
                let start = w.content.location(w.content.documentRange.location, offsetBy: range.location)!
                var found: [CGRect] = []
                w.layout.enumerateTextSegments(
                    in: NSTextRange(location: start, end: w.content.location(start, offsetBy: range.length))!, type: type, options: .rangeNotRequired
                ) { _, rect, _, _ in
                    found.append(rect)
                    return true
                }
                return found
            }
            func isInOneCell(_ rect: CGRect, lineHigh: Bool = true) -> Bool {
                (0..<4).contains { rect.minX >= edges[$0] && rect.maxX <= edges[$0 + 1] } && rect.minY >= table.minY && rect.maxY <= table.maxY
                    && (!lineHigh || rect.height == theme.bodyLineHeight)
            }
            let start = w.offset(of: "laptop setup"), platform = w.offset(of: "Platform"), length = w.offset(of: "shipped to") + 4 - start
            // Inside one cell, over its line ends.
            let inCell = segments(NSRange(location: start, length: length), .selection)
            #expect(inCell.count >= 3 && inCell.allSatisfy { isInOneCell($0) } && inCell.allSatisfy { $0.minX >= edges[2] })
            #expect(inCell.dropFirst().dropLast().allSatisfy { $0.minX == edges[2] + theme.hairlineWidth && $0.maxX == edges[3] }, "whole lines from border to border")
            #expect(abs(inCell[0].minX - w.caretRect(at: start).minX) < 0.01 && abs(inCell.last!.maxX - w.caretRect(at: start + length).minX) < 0.01)
            // From one cell into the next and on into the next row.
            let across = segments(NSRange(location: platform + 3, length: w.offset(of: "start |") - platform), .selection)
            #expect(across.allSatisfy { isInOneCell($0, lineHigh: false) } && Set(across.map { rect in (0..<4).first { rect.minX >= edges[$0] && rect.maxX <= edges[$0 + 1] }! }) == [0, 1, 2, 3])
            #expect(across.reduce(0) { $0 + $1.width * $1.height } > 0)
            // Rows that are selected whole are filled whole, as in a grid of single lines: no strip
            // is left out between them, in a row's padding or under a cell with fewer lines.
            let rows = [w.offset(of: "| Area"), w.offset(of: "| Onboarding"), w.offset(of: "| **Bold**")].map { box(w, ofRowAt: $0) }
            let whole = segments(NSRange(location: w.offset(of: "| Area"), length: w.offset(of: "| short") - w.offset(of: "| Area")), .selection)
            for row in rows {
                for column in 0..<4 {
                    let cell = CGRect(x: edges[column] + theme.hairlineWidth, y: row.minY, width: edges[column + 1] - edges[column] - theme.hairlineWidth, height: row.height)
                    let filled = whole.reduce(0) { $0 + $1.intersection(cell).width * $1.intersection(cell).height }
                    #expect(abs(filled - cell.width * cell.height) < 1, "column \(column) of the row at \(row.minY): \(filled) of \(cell.width * cell.height)")
                }
            }
            // The hidden delimiter row apart.
            #expect(whole.allSatisfy { isInOneCell($0, lineHigh: false) || $0.height < 1 })
            // What the find bar's indicator and the spelling panel go by.
            for type in [NSTextLayoutManager.SegmentType.standard, .highlight] {
                let found = segments(NSRange(location: w.offset(of: "buddy programme"), length: 15), type)
                #expect(!found.isEmpty && found.allSatisfy { isInOneCell($0) } && found.allSatisfy { $0.minX >= edges[2] && $0.width > 20 }, "\(type.rawValue): \(found)")
            }
            // And on the screen: the selection's colour inside the cell, the row's own beside it.
            w.window.makeKey()
            w.select(start, length: length)
            w.pump()
            let pixels = drawn(w), plain = pixels.color(edges[1] - 8, inCell[1].midY)
            #expect(pixels.color(edges[2] + 4, inCell[1].midY) != plain && pixels.color(edges[3] - 4, inCell[1].midY) != plain)
            #expect(pixels.color(edges[3] + 6, inCell[1].midY) == plain, "nothing beyond the cell's border")
        }

        @Test func shiftAndTheArrowKeysSelectInTheOrderOfTheText() {
            // In a page as wide as the text column, where "reading list" is on its cell's third line.
            let w = window(sample, size: NSSize(width: theme.maximumTextWidth + 2 * theme.pagePadding.width, height: 600))
            defer { w.close() }
            let start = w.offset(of: "reading list")
            w.select(start)
            for _ in 0..<5 { w.command(#selector(NSResponder.moveRightAndModifySelection(_:))) }
            #expect(w.textView.selectedRange() == NSRange(location: start, length: 5))
            for _ in 0..<8 { w.command(#selector(NSResponder.moveLeftAndModifySelection(_:))) }
            #expect(w.textView.selectedRange() == NSRange(location: start - 3, length: 3))
            // Through the end of a cell into the next one.
            let end = w.offset(of: "Platform") + 8
            w.select(end - 2)
            for _ in 0..<5 { w.command(#selector(NSResponder.moveRightAndModifySelection(_:))) }
            #expect(w.textView.selectedRange().location == end - 2 && NSMaxRange(w.textView.selectedRange()) > w.offset(of: "Everything"))
            // Down with Shift: to the line below in the cell, straight below; the keys that follow move that end.
            let caret = w.caretRect(at: start + 3)
            w.select(start + 3)
            w.command(#selector(NSResponder.moveDownAndModifySelection(_:)))
            var selection = w.textView.selectedRange()
            var head = w.caretRect(at: NSMaxRange(selection))
            #expect(selection.location == start + 3 && abs(head.minY - caret.minY - theme.bodyLineHeight) < 0.1 && abs(head.minX - caret.minX) < 6, "\(selection): \(head) below \(caret)")
            w.command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: start + 3, length: selection.length - 1))
            w.command(#selector(NSResponder.moveDownAndModifySelection(_:)))
            w.command(#selector(NSResponder.moveDownAndModifySelection(_:)))
            selection = w.textView.selectedRange()
            #expect(selection.location == start + 3 && w.caretRect(at: NSMaxRange(selection)).minY > head.minY + theme.bodyLineHeight, "on into the row below, in the same column")
            // Up with Shift: the start moves, and stays the end that moves.
            w.select(start + 3)
            w.command(#selector(NSResponder.moveUpAndModifySelection(_:)))
            selection = w.textView.selectedRange()
            head = w.caretRect(at: selection.location)
            #expect(NSMaxRange(selection) == start + 3 && abs(head.minY - caret.minY + theme.bodyLineHeight) < 0.1 && abs(head.minX - caret.minX) < 6, "\(selection): \(head) above \(caret)")
            w.command(#selector(NSResponder.moveRightAndModifySelection(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: selection.location + 1, length: selection.length - 1))
            // On up into the header row, over break tags and markers on the way: still the same column.
            w.command(#selector(NSResponder.moveUpAndModifySelection(_:)))
            w.command(#selector(NSResponder.moveUpAndModifySelection(_:)))
            selection = w.textView.selectedRange()
            #expect(NSMaxRange(selection) == start + 3 && selection.location >= w.offset(of: "What it covers") && selection.location <= w.offset(of: "What it covers") + 14, "\(selection)")
            // And from a cell of the last column up to the row above, across the rows' other cells.
            w.select(w.offset(of: "c |"))
            w.command(#selector(NSResponder.moveUpAndModifySelection(_:)))
            selection = w.textView.selectedRange()
            #expect(NSMaxRange(selection) == w.offset(of: "c |") && selection.location > w.offset(of: "Laptop") && selection.location <= w.offset(of: "Buddy") + 5, "\(selection)")
            // From the line above the table into it, and from its last line out of it.
            let intro = w.offset(of: "intro line") + 4
            w.select(intro)
            w.command(#selector(NSResponder.moveDownAndModifySelection(_:)))
            w.command(#selector(NSResponder.moveDownAndModifySelection(_:)))
            selection = w.textView.selectedRange()
            #expect(selection.location == intro && NSMaxRange(selection) > w.offset(of: "| Area") && NSMaxRange(selection) <= w.offset(of: "Area") + 4, "\(selection)")
            #expect(w.textView.string == sample)
        }

        @Test func shiftAndLeftOrRightGoThroughTheWholeTable() {
            // The last cells of the rows, and cells that hold nothing but a tag or a marked word, are where the text view's own moves stuck.
            let source = "before the table\n\n| Name | Text | More |\n|---|---|---|\n| one | \(Self.sentence) | \(Self.sentence) |\n| two | **b** | **b** |\n"
                + "| three | <br> | `c` |\n| four | pq | rs |\n\nafter"
            let w = window(source)
            defer { w.close() }
            #expect(row(w, at: w.offset(of: "| four"))?.cellStarts.count == 3)
            let text = source as NSString, start = 10, end = w.length - 2
            w.select(start)
            var ends = [start]
            for _ in 0..<w.length where ends.last != end {
                press(w, arrow: NSRightArrowFunctionKey, .shift)
                ends.append(NSMaxRange(w.textView.selectedRange()))
                guard w.textView.selectedRange().location == start, ends[ends.count - 1] > ends[ends.count - 2] else { break }
            }
            #expect(ends.last == end && zip(ends, ends.dropFirst()).allSatisfy { $0 < $1 }, "\(ends)")
            // No more than a hidden pipe with its blanks, or the hidden delimiter row, is passed in one press.
            #expect(zip(ends, ends.dropFirst()).allSatisfy { $1 - $0 == 1 || text.substring(with: NSRange(location: $0, length: $1 - $0)).contains("|") })
            // Back: the same end moves back.
            press(w, arrow: NSLeftArrowFunctionKey, .shift)
            #expect(w.textView.selectedRange() == NSRange(location: start, length: end - 1 - start))

            w.select(end)
            var starts = [end]
            for _ in 0..<w.length where starts.last != start {
                press(w, arrow: NSLeftArrowFunctionKey, .shift)
                starts.append(w.textView.selectedRange().location)
                guard NSMaxRange(w.textView.selectedRange()) == end, starts[starts.count - 1] < starts[starts.count - 2] else { break }
            }
            #expect(starts.last == start && zip(starts, starts.dropFirst()).allSatisfy { $0 > $1 }, "\(starts)")
            // The start stays the end that moves, for the text view's own keys too: by word, and Right again.
            press(w, arrow: NSRightArrowFunctionKey, .shift)
            #expect(w.textView.selectedRange() == NSRange(location: start + 1, length: end - start - 1))
            w.command(#selector(NSResponder.moveWordLeftAndModifySelection(_:)))
            #expect(NSMaxRange(w.textView.selectedRange()) == end && w.textView.selectedRange().location < start)
            #expect(w.textView.string == source)
        }

        @Test func rightGoesThroughACellThatHoldsOnlyABreakTag() {
            let source = "before\n\n| Key | Mixed | Wide | Tail |\n|-----|-----|------|-----|\n| **bold start** and then quite a lot more text so it wraps around in this cell twice "
                + "| <br> | x | a long tail of words to wrap the cell around more than once here, and on and on it goes for a while |\n\nend"
            let w = window(source, size: NSSize(width: 900, height: 900))
            defer { w.close() }
            let end = w.offset(of: "end") + 3
            w.select(w.offset(of: "bold start"))
            var stops = [w.textView.selectedRange().location]
            for _ in 0..<w.length where stops.last != end {
                press(w, arrow: NSRightArrowFunctionKey)
                // The window is drawn between the keys, as it is for a person's.
                w.pump(0.02)
                stops.append(w.textView.selectedRange().location)
                guard stops[stops.count - 1] > stops[stops.count - 2] else { break }
            }
            #expect(stops.last == end && (w.offset(of: "<br>")...w.offset(of: "<br>") + 4).allSatisfy(stops.contains), "\(stops)")
            #expect(w.textView.string == source)
        }

        @Test func theEndOfALineThatWrapsIsAPlaceOnThatLine() throws {
            let source = "before the table\n\n| Name | Text | More |\n|---|---|---|\n| one | \(Self.sentence) and \(Self.sentence) | \(Self.sentence) |\n| two | pq | rs |\n\nafter"
            let w = window(source)
            defer { w.close() }
            let origin = w.textView.textContainerOrigin, line = rows(w)[1].line, cell = line.cells[1], edges = try #require(row(w, at: line.range.location)).edges
            let starts = lineStarts(w, cell)
            #expect(starts.count >= 3)
            for (start, next) in zip(starts, starts.dropFirst()) {
                let top = w.caretRect(at: start).minY, end = next - 1
                #expect(w.caretRect(at: end).minY == top && w.caretRect(at: next).minY > top)
                // A click to the right of the line's end.
                w.select(0)
                w.placeCaret(at: NSPoint(x: origin.x + edges[2] - 3, y: origin.y + top + theme.bodyLineHeight / 2))
                #expect(w.textView.selectedRange() == NSRange(location: end, length: 0), "a click beside the line that starts at \(start)")
                // Command-Right from anywhere on the line, and Command-Left back; again, they stay.
                for from in [start, start + 5, end] {
                    w.select(from)
                    w.command(#selector(NSResponder.moveToEndOfLine(_:)))
                    #expect(w.textView.selectedRange() == NSRange(location: end, length: 0), "to the end from \(from)")
                    w.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
                    #expect(w.textView.selectedRange() == NSRange(location: start, length: 0), "to the start from \(from)")
                    w.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
                    #expect(w.textView.selectedRange() == NSRange(location: start, length: 0))
                }
                // With Shift the line is selected, from either end.
                w.select(start + 5)
                w.command(#selector(NSResponder.moveToEndOfLineAndModifySelection(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: start + 5, length: end - start - 5))
                w.select(start + 5)
                w.command(#selector(NSResponder.moveToBeginningOfLineAndModifySelection(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: start, length: 5))
                w.command(#selector(NSResponder.moveRightAndModifySelection(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: start + 1, length: 4), "the start is the end that moves")
            }
            // On a cell's last line the end is the end of its text, and the start of a cell's first line is in the cell.
            for (index, row) in rows(w) {
                _ = index
                for cell in row.cells where cell.contentRange.length > 0 {
                    w.select(cell.contentRange.location + 1)
                    w.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
                    #expect(w.textView.selectedRange() == NSRange(location: cell.contentRange.location, length: 0), "\(cell.contentRange)")
                    w.select(NSMaxRange(cell.contentRange) - 1)
                    w.command(#selector(NSResponder.moveToEndOfLine(_:)))
                    #expect(w.caretRect(at: w.textView.selectedRange().location).minY == w.caretRect(at: NSMaxRange(cell.contentRange)).minY
                        && NSLocationInRange(w.textView.selectedRange().location, NSRange(location: NSMaxRange(cell.contentRange), length: 2)), "\(cell.contentRange)")
                }
            }
            #expect(w.textView.string == source)
        }

        @Test func upFromBesideTheEndOfTheLineAboveGoesToThatEnd() throws {
            let word = String(repeating: "b", count: 94)
            let source = "before the table\n\n| Name | Text | More |\n|---|---|---|\n| one | aa \(word) cc dd ee ff | \(Self.sentence) \(Self.sentence) \(Self.sentence) |\n| two | pq | rs |\n\nafter"
            let w = window(source)
            defer { w.close() }
            let cell = rows(w)[1].line.cells[1], starts = lineStarts(w, cell), table = box(w, ofRowAt: w.offset(of: "| Name"))
            #expect(starts.count >= 3 && starts[1] == w.offset(of: word))
            // From every place of the row: Up comes to a line higher each time and leaves the table.
            for from in stride(from: w.offset(of: "| one") + 2, to: w.offset(of: "| two") - 3, by: 3) {
                w.select(from)
                var tops = [w.caretRect(at: w.textView.selectedRange().location).minY]
                for _ in 0..<20 where tops.last! >= table.minY {
                    press(w, arrow: NSUpArrowFunctionKey)
                    tops.append(w.caretRect(at: w.textView.selectedRange().location).minY)
                    guard tops[tops.count - 1] < tops[tops.count - 2] else { break }
                }
                #expect(tops.last! < table.minY && zip(tops, tops.dropFirst()).allSatisfy { $0 > $1 }, "from \(from): \(tops)")
            }
            // From the end of the long word on its last line, beside the short first line: to that line's end.
            w.select(NSMaxRange(cell.contentRange) - 12)
            let last = w.textView.selectedRange().location
            #expect(w.caretRect(at: last).minX > w.caretRect(at: starts[1] - 1).minX + 40)
            while w.caretRect(at: w.textView.selectedRange().location).minY > w.caretRect(at: starts[1]).minY { press(w, arrow: NSUpArrowFunctionKey) }
            press(w, arrow: NSUpArrowFunctionKey)
            #expect(w.textView.selectedRange() == NSRange(location: starts[1] - 1, length: 0), "behind 'aa'")
            #expect(w.textView.string == source)
        }

        // MARK: editing

        @Test func typingReflowsTheCellGrowsTheRowAndUndoesExactly() throws {
            let w = window(sample)
            defer { w.close() }
            let at = w.offset(of: "Short cell.") + 11, line = w.offset(of: "| short")
            let height = w.fragment(at: line).layoutFragmentFrame.height, edges = try #require(row(w, at: line)).edges
            w.select(at)
            let typed = " Now it grows, word by word, until the text of this cell needs a second and then a third line of its column."
            w.type(typed)
            w.pump()
            let expected = (sample as NSString).replacingCharacters(in: NSRange(location: at, length: 0), with: typed)
            #expect(w.textView.string == expected && w.textView.selectedRange() == NSRange(location: at + (typed as NSString).length, length: 0))
            #expect(w.fragment(at: line).layoutFragmentFrame.height >= height + theme.bodyLineHeight, "the row grew")
            #expect((w.fragment(at: line) as? BlockFragment)?.fitsItsCells == true && row(w, at: line)?.cellStarts.count == 4)
            let caret = w.caretRect(at: w.textView.selectedRange().location)
            #expect(caret.minX > edges[2] && caret.maxX < edges[3] && caret.minY > w.caretRect(at: at).minY, "the caret is where the text went")
            // Characters deleted from the middle, a word at the cell's start, one at its end.
            w.select(at + 5)
            w.type(String(repeating: String(EditorWindow.backspace), count: 4))
            w.select(w.offset(of: "Short cell."))
            w.type("A ")
            w.select(w.offset(of: "Platform") + 8)
            w.type("s")
            let edited = w.textView.string
            #expect(edited.contains("| A Short cell. it grows") && edited.contains("| Platforms |") && w.storageProblem == nil)
            w.undoAll()
            #expect(w.textView.string == sample)
            #expect(w.fragment(at: line).layoutFragmentFrame.height == height && row(w, at: line)?.edges == edges)
            while w.textView.undoManager?.canRedo == true { w.textView.undoManager?.redo() }
            w.pump()
            #expect(w.textView.string == edited && (w.fragment(at: line) as? BlockFragment)?.fitsItsCells == true)
        }

        @Test func aKeyThatLeavesTheColumnsAloneRendersOnlyItsOwnRow() throws {
            let w = window(sample)
            defer { w.close() }
            func paragraph(_ offset: Int) -> NSTextElement? { w.layout.textLayoutFragment(for: w.content.location(w.content.documentRange.location, offsetBy: offset)!)?.textElement }
            let header = w.offset(of: "| Area"), first = w.offset(of: "| Onboarding"), edges = try #require(row(w, at: header)).edges
            let before = [paragraph(header), paragraph(first)]
            w.select(w.offset(of: "Short cell.") + 5)
            w.type("!")
            w.pump()
            #expect(row(w, at: header)?.edges == edges)
            #expect(paragraph(header) === before[0] && paragraph(first) === before[1], "the other rows were not made again")
        }

        @Test func tabReturnAndATypedPipeWorkAsInAGridOfSingleLines() throws {
            let w = window(sample)
            defer { w.close() }
            func content(_ word: String, _ length: Int) -> NSRange { NSRange(location: w.offset(of: word), length: length) }
            w.select(w.offset(of: "Onboarding") + 3)
            w.type("\t")
            #expect(w.textView.selectedRange() == content("Platform", 8))
            w.type("\t")
            #expect(w.textView.selectedRange() == content("Everything", (Self.long as NSString).length))
            w.type("\t")
            #expect(w.textView.selectedRange() == content("Laptop<br>", 46))
            w.type("\t")
            #expect(w.textView.selectedRange() == content("**Bold** start", 14), "from the last cell to the first of the next row")
            w.type(String(EditorWindow.backtab) + String(EditorWindow.backtab))
            #expect(w.textView.selectedRange() == content("Everything", (Self.long as NSString).length))
            // Return goes to the row below, in the same column.
            w.select(w.offset(of: "Platform") + 2)
            w.type("\r")
            #expect(w.textView.selectedRange().location == w.offset(of: "x |"))
            // A pipe typed into a cell is escaped and stays in the cell.
            w.select(w.offset(of: "Short cell.") + 5)
            w.type("|")
            #expect(w.textView.string.contains("| Short\\| cell. |") && map(w).lines[6].cells.count == 4)
            w.select(w.offset(of: "last<BR />") + 2)
            w.pump()
            #expect(w.displayParagraph(at: w.offset(of: "Short\\|") + 5).text.string.contains("Short\u{200C}| cell."), "its backslash is hidden")
            // Tab in the last cell of the last row adds a row.
            w.type("\t")
            #expect(map(w).tables.first?.lines.count == 6 && w.textView.string.contains("one |\n|  |  |  |  |\n\nend"))
            #expect(row(w, at: w.textView.selectedRange().location)?.cellStarts.count == 4)
            w.type("new")
            #expect(w.textView.string.contains("\n| new |  |  |  |\n"))
            w.undoAll()
            #expect(w.textView.string == sample && w.storageProblem == nil)
        }

        @Test func everyTableCommandDoesWhatItDoesInAGridOfSingleLines() {
            var run: Set<String> = []
            for caret in ["reading list", "Onboarding"] {
                for item in EditorTextView.tableMenu().items where !item.isSeparatorItem {
                    let w = window(sample)
                    defer { w.close() }
                    w.select(w.offset(of: caret) + 2)
                    guard w.textView.validateUserInterfaceItem(item) else { continue }
                    run.insert(item.title)
                    let command = TableCommand.allCases[item.tag]
                    let expected = TableEdits.edit(command, in: sample, map: map(w), selection: w.textView.selectedRange())
                    w.textView.performTableCommand(item)
                    w.pump(0.01)
                    let edited = w.textView.string
                    #expect(expected != nil && edited == (sample as NSString).replacingCharacters(in: expected!.range, with: expected!.replacement), "\(item.title)")
                    #expect(edited != sample && map(w).tables.count == 1, "\(item.title)")
                    // Still a grid: of wrapping cells, or without the long column of single lines.
                    for (_, line) in rows(w) {
                        let cells = row(w, at: line.range.location)?.cellStarts.count
                        #expect(cells == line.cells.count || cells == 0 && command == .deleteColumn, "\(item.title)")
                        #expect((w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true, "\(item.title)")
                    }
                    w.textView.undoManager?.undo()
                    w.pump(0.01)
                    #expect(w.textView.string == sample && w.textView.undoManager?.canUndo == false, "\(item.title) is one step")
                    w.textView.undoManager?.redo()
                    w.pump(0.01)
                    #expect(w.textView.string == edited && w.storageProblem == nil, "redo \(item.title)")
                }
            }
            #expect(run.count == TableCommand.allCases.count, "\(run)")
        }

        @Test func markedTextOfAnInputMethodIsComposedInItsCell() throws {
            let w = window(sample)
            defer { w.close() }
            let at = w.offset(of: "Short cell.") + 5, edges = try #require(row(w, at: at)).edges
            w.select(at)
            w.textView.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: at, length: 0))
            w.pump()
            #expect(w.textView.hasMarkedText() && w.textView.markedRange() == NSRange(location: at, length: 4))
            let marked = w.caretRect(at: at + 4), start = w.caretRect(at: at)
            #expect(marked.minX > start.minX + 30 && marked.maxX < edges[3] && marked.minY == start.minY, "the composition is laid out in the cell")
            #expect(row(w, at: at)?.cellStarts.count == 4)
            w.textView.insertText("日本語", replacementRange: w.textView.markedRange())
            w.pump()
            #expect(!w.textView.hasMarkedText() && w.textView.string.contains("| Short日本語 cell. |") && w.textView.selectedRange().location == at + 3)
            #expect((w.fragment(at: at) as? BlockFragment)?.fitsItsCells == true)
            w.undoAll()
            #expect(w.textView.string == sample && w.storageProblem == nil)
        }

        @Test func aLinkInAWrappedCellIsFoundUnderTheMouse() {
            let w = window(sample)
            defer { w.close() }
            var opened: [URL] = []
            w.editor.linkOpener = { opened.append($0) }
            let caret = w.caretRect(at: w.offset(of: "[link]") + 3), origin = w.textView.textContainerOrigin
            w.mouseDown(at: NSPoint(x: caret.minX + origin.x + 2, y: caret.midY + origin.y), modifiers: .command)
            #expect(opened.map(\.absoluteString) == ["http://example.org/a"])
        }

        @Test func spellingIsNotMarkedInARowOfWrappingCellsAndAMarkFromBeforeDoesNotShowOnAnotherLine() {
            let w = window(sample + "\n| a | b |\n|---|---|\n| wrrd | x |\n")
            defer { w.close() }
            func range(_ word: String) -> NSRange { NSRange(location: w.offset(of: word), length: (word as NSString).length) }
            func state(_ word: String) -> Int { w.editor.textView(w.textView, shouldSetSpellingState: 1, range: range(word)) }
            #expect(state("Onboarding") == 0 && state("programme") == 0 && state("Buddy") == 0)
            #expect(state("intro") == 1 && state("wrrd") == 1, "a paragraph and a grid of single lines")
            // One that was set while the table showed on single lines stays with the text. The line
            // would draw it 18 pt too low: across the next line of its cell, or below the row.
            func picture() -> Data {
                let bitmap = w.textView.bitmapImageRepForCachingDisplay(in: w.textView.bounds)!
                w.textView.cacheDisplay(in: w.textView.bounds, to: bitmap)
                return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            }
            func mark(_ word: String) {
                let start = w.content.location(w.content.documentRange.location, offsetBy: range(word).location)!
                w.layout.addRenderingAttribute(.spellingState, value: 1, for: NSTextRange(location: start, end: w.content.location(start, offsetBy: range(word).length))!)
                w.pump()
            }
            let before = picture()
            for word in ["programme", "Platform", "Buddy", "last"] { mark(word) }
            #expect(picture() == before, "second and later lines of a cell, and every cell but the first")
            mark("intro")
            #expect(picture() != before, "the same in a paragraph shows")
        }

        // MARK: the fixture

        @Test func theWideFixtureShowsAsAGridWithWrappingCellsAtTheDefaultWindowSize() throws {
            let source = try String(contentsOf: Fixtures.url("wide-table.md"), encoding: .utf8)
            let w = window(source, size: NSSize(width: 900, height: 1000))
            defer { w.close() }
            let rows = rows(w)
            #expect(rows.count == 5)
            for (_, line) in rows {
                let grid = try #require(row(w, at: line.range.location))
                #expect(grid.cellStarts.count == 4 && grid.edges[0] >= 0 && grid.edges.last! <= pageWidth(w) && (w.fragment(at: line.range.location) as? BlockFragment)?.fitsItsCells == true)
                for cell in line.cells where line.kind == .tableRow(isHeader: false) {
                    #expect((200...470).contains(cell.contentRange.length), "\(cell.contentRange.length) characters")
                }
            }
            #expect(source.components(separatedBy: "<br>").count > 12)
            #expect(w.textView.string == source && w.storageProblem == nil)
        }
    }
}
