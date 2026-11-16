import AppKit
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// Tables as laid out, drawn and edited in a real window.
    @Suite struct TableTests {
        private let theme = Theme.standard

        private let sample = """
            intro

            | Name | Qty | Note |
            |:-----|----:|:----:|
            | apple | 3 | plain |
            | a **bold** cell | 12 | green |
            | kiwi | 7 | **red** |
            | [site](http://example.org/a/long/path) | 1 | x |

            end
            """

        /// An editor on `source` with the caret parked at the very end, away from everything.
        private func window(_ source: String, size: NSSize = NSSize(width: 900, height: 600)) -> EditorWindow {
            let w = EditorWindow(source, size: size)
            w.select(w.length)
            w.pump()
            return w
        }

        private func offset(_ text: String, in w: EditorWindow) -> Int {
            (w.textView.string as NSString).range(of: text).location
        }

        private func map(_ w: EditorWindow) -> StyleMap { MarkdownStyler.style(w.textView.string) }

        private func gridRow(_ w: EditorWindow, at offset: Int) -> TableRow? {
            w.displayAttributes(at: offset)[.tableRow] as? TableRow
        }

        /// Right edge of the character at `offset`, from the left edge of the text column.
        private func columnMaxX(_ w: EditorWindow, at offset: Int) -> CGFloat {
            w.characterRect(at: offset).maxX - w.textView.columnLeft
        }

        /// For each column of the first table, how far its aligned edge (the left edge, the right
        /// edge or the middle of the cell's text) differs between the rows, and from where the grid puts it.
        private func spread(_ w: EditorWindow) -> CGFloat {
            let map = map(w)
            guard let table = map.tables.first else { return .infinity }
            var worst: CGFloat = 0
            for (column, alignment) in table.alignments.enumerated() {
                var positions: [CGFloat] = []
                for index in table.lines where index != table.lines.lowerBound + 1 {
                    let line = map.lines[index]
                    guard let row = gridRow(w, at: line.range.location) else { return .infinity }
                    // A short row has no cell here.
                    guard column + 1 < line.pipes.count else { continue }
                    let left = w.columnX(at: line.pipes[column] + 1), right = columnMaxX(w, at: line.pipes[column + 1] - 1)
                    let padding = theme.tableCellPadding.width
                    switch alignment {
                    case .left, .none: positions += [left, row.edges[column] + padding]
                    case .right: positions += [right, row.edges[column + 1] - padding]
                    case .center: positions += [(left + right) / 2, (row.edges[column] + row.edges[column + 1]) / 2]
                    }
                    // No cell's text reaches into its neighbour's.
                    if left < row.edges[column] - 0.5 || right > row.edges[column + 1] + 0.5 { return .infinity }
                }
                worst = max(worst, (positions.max() ?? 0) - (positions.min() ?? 0))
            }
            return worst
        }

        /// Every table shows either all of its rows in the grid, each within the grid, or none.
        private func spilled(_ w: EditorWindow) -> String? {
            let map = map(w), text = w.textView.string as NSString
            for line in map.lines where line.range.length > 0 {
                let row = gridRow(w, at: line.range.location)
                let isRow = if case .tableRow = line.kind { true } else { false }
                if row != nil, !isRow { return "a grid row that is no table row at \(line.range)" }
                guard let row else { continue }
                var end = 0
                text.getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: line.range.location, length: 0))
                // Where the cells wrap, every line stands in its cell: WrappedTableTests.
                if !row.cellStarts.isEmpty { continue }
                let stops = (w.displayAttributes(at: line.range.location)[.paragraphStyle] as? NSParagraphStyle)?.tabStops.count ?? 0
                if line.pipes.count > stops { return "more pipes than stops at \(line.range)" }
                if end > line.range.location, columnMaxX(w, at: end - 1) > row.edges[row.edges.count - 1] + 0.5 {
                    return "text beyond the grid at \(line.range)"
                }
            }
            for table in map.tables {
                let rows = table.lines.filter { $0 != table.lines.lowerBound + 1 }.map { gridRow(w, at: map.lines[$0].range.location) != nil }
                if Set(rows).count > 1 { return "a table partly in the grid at line \(table.lines.lowerBound)" }
            }
            return nil
        }

        // MARK: rendering

        @Test func pipesBecomeTabsWithOneStopEach() throws {
            let w = window(sample)
            defer { w.close() }
            let map = map(w), table = try #require(map.tables.first)
            for index in table.lines where index != table.lines.lowerBound + 1 {
                let line = map.lines[index]
                let (shown, _) = w.displayParagraph(at: line.range.location)
                for pipe in line.pipes {
                    #expect((shown.string as NSString).character(at: pipe - line.range.location) == 0x09)
                }
                let style = try #require(w.displayAttributes(at: line.range.location)[.paragraphStyle] as? NSParagraphStyle)
                #expect(style.tabStops.count == line.pipes.count)
                #expect(style.tabStops.map(\.alignment) == [.left, .right, .center, .left])
                #expect(style.lineBreakMode == .byClipping)
                #expect(w.fragment(at: line.range.location).textLineFragments.count == 1)
                #expect(abs(w.fragment(at: line.range.location).layoutFragmentFrame.height
                    - theme.bodyLineHeight - 2 * theme.tableCellPadding.height
                    - (index == table.lines.lowerBound || index == table.lines.upperBound - 1 ? theme.tableMargin : 0)) < 0.01)
            }
            #expect(w.displayFont(at: offset("Name", in: w)) == theme.tableHeaderFont)
            #expect(w.displayFont(at: offset("apple", in: w)) == theme.tableFont(isHeader: false, isCompact: false))
            #expect(spread(w) <= 0.5)
            #expect(spilled(w) == nil)
            #expect(w.textView.string == sample)
            #expect(w.storageProblem == nil)
        }

        @Test func theDelimiterRowTakesNoRoom() {
            let w = window(sample)
            defer { w.close() }
            let delimiter = offset("|:-----", in: w)
            #expect(w.fragment(at: delimiter).layoutFragmentFrame.height <= 0.02)
            #expect((delimiter..<delimiter + 22).allSatisfy(w.isHidden))
            #expect(gridRow(w, at: delimiter) == nil)
        }

        @Test func inlineMarkdownIsRenderedInsideCells() {
            let w = window(sample)
            defer { w.close() }
            let bold = offset("**bold**", in: w), link = offset("[site]", in: w)
            #expect(w.isHidden(bold) && w.isHidden(bold + 1) && w.isHidden(bold + 6))
            #expect(w.displayFont(at: bold + 2).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.isHidden(link) && w.isHidden(link + 10), "the link's brackets and URL")
            #expect(w.displayAttributes(at: link + 1)[.foregroundColor] as? NSColor == theme.link)
            // Touching a token shows its markers, as anywhere else.
            w.select(bold + 3)
            w.pump()
            #expect(!w.isHidden(bold) && !w.isHidden(bold + 6))
            #expect(w.displayAttributes(at: bold)[.foregroundColor] as? NSColor == theme.marker)
        }

        @Test func columnsStayAlignedAcrossRowsThroughEditsUndoAndReveal() {
            let w = window(sample)
            defer { w.close() }
            let initial = gridRow(w, at: offset("| Name", in: w))?.edges
            #expect(spread(w) <= 0.5)

            // Typing widens the column in every row.
            w.select(offset("apple", in: w) + 5)
            w.type(" and a much longer name")
            w.pump()
            #expect(spread(w) <= 0.5)
            let widened = gridRow(w, at: offset("| Name", in: w))?.edges
            #expect((widened?[1] ?? 0) > (initial?[1] ?? 0) + 50)
            w.undoAll()
            #expect(w.textView.string == sample)
            #expect(spread(w) <= 0.5)
            #expect(gridRow(w, at: offset("| Name", in: w))?.edges == initial)
            w.textView.undoManager?.redo()
            w.pump()
            #expect(spread(w) <= 0.5)
            #expect(gridRow(w, at: offset("| kiwi", in: w))?.edges == widened)
            w.undoAll()

            // Revealed markers widen their cell; the columns of all rows follow.
            for token in ["**bold**", "**red**", "[site]"] {
                w.select(offset(token, in: w) + 3)
                w.pump()
                #expect(!w.isHidden(offset(token, in: w)), "\(token) is revealed")
                #expect(spread(w) <= 0.5, "caret in \(token)")
            }
            let revealed = gridRow(w, at: offset("| Name", in: w))?.edges
            #expect((revealed?[1] ?? 0) > (initial?[1] ?? 0) + 100, "the link's URL takes its room")
            w.select(w.length)
            w.pump()
            #expect(spread(w) <= 0.5)
            #expect(gridRow(w, at: offset("| Name", in: w))?.edges == initial)
            #expect(w.storageProblem == nil)
        }

        /// The display paragraph of the line at `offset` as it is laid out now.
        private func shownParagraph(_ w: EditorWindow, at offset: Int) -> NSTextParagraph? {
            w.fragment(at: offset).textElement as? NSTextParagraph
        }

        @Test func aKeyThatLeavesTheColumnsAloneRendersOnlyItsOwnRow() throws {
            let w = window(sample)
            defer { w.close() }
            let kiwi = offset("kiwi", in: w), apple = offset("| apple", in: w), header = offset("| Name", in: w)
            let before = [header, apple].map { shownParagraph(w, at: $0) }
            // "kiwi!" is still narrower than the widest cell of its column.
            w.select(kiwi + 4)
            w.type("!")
            w.pump()
            #expect(w.textView.string.contains("| kiwi! |"))
            #expect(shownParagraph(w, at: header) === before[0], "the header row was not made again")
            #expect(shownParagraph(w, at: apple) === before[1], "nor a row above the edited one's neighbour")
            #expect(spread(w) <= 0.5)
            // A key that widens the column moves every row.
            w.type(" and a much longer name")
            w.pump()
            #expect(shownParagraph(w, at: header) !== before[0])
            #expect(spread(w) <= 0.5)
            #expect(spilled(w) == nil)
        }

        /// MEASURED: 22 to 29 ms a key in a 2,000-row table that shows as source, every row
        /// rendered again although rows of source share nothing.
        @Test func aKeyInATableShownAsSourceRendersOnlyItsOwnRow() throws {
            // A row with a cell too many: not a regular table, so it shows as source.
            let w = window(sample.replacingOccurrences(of: "| apple | 3 | plain |", with: "| apple | 3 | plain | more |"))
            defer { w.close() }
            let header = offset("| Name", in: w), apple = offset("| apple", in: w)
            #expect(gridRow(w, at: header) == nil && w.displayAttributes(at: header)[.codePanel] != nil)
            let before = [header, apple].map { shownParagraph(w, at: $0) }
            w.select(offset("kiwi", in: w) + 4)
            w.type("!")
            w.pump()
            #expect(w.textView.string.contains("| kiwi! |"))
            #expect(shownParagraph(w, at: header) === before[0] && shownParagraph(w, at: apple) === before[1], "the other rows were not made again")
            // The edit that makes a grid of it reaches every row.
            w.textView.insertText("", replacementRange: (w.textView.string as NSString).range(of: " more |"))
            w.pump()
            #expect(gridRow(w, at: header) != nil && gridRow(w, at: offset("| kiwi", in: w)) != nil)
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            // And the one that makes source of it again.
            w.textView.insertText(" | more", replacementRange: NSRange(location: offset("| kiwi", in: w) + 7, length: 0))
            w.pump()
            #expect(gridRow(w, at: header) == nil && gridRow(w, at: offset("| kiwi", in: w)) == nil)
            #expect(spilled(w) == nil && w.storageProblem == nil)
        }

        @Test func otherTextOfTheSameLengthMovesTheColumnsToo() throws {
            let w = window(sample)
            defer { w.close() }
            let initial = try #require(gridRow(w, at: offset("| Name", in: w))?.edges)
            // No style of the row changes: four characters stand where four stood.
            let cell = (w.textView.string as NSString).range(of: "cell")
            w.textView.insertText("WWWW", replacementRange: cell)
            w.pump()
            #expect(w.textView.string.contains("| a **bold** WWWW |"))
            let widened = try #require(gridRow(w, at: offset("| Name", in: w))?.edges)
            #expect(widened[1] > initial[1] + 10)
            #expect(gridRow(w, at: offset("| kiwi", in: w))?.edges == widened)
            #expect(spread(w) <= 0.5)
        }

        /// Every table line shows as it does in a window that has only just loaded the same text:
        /// whatever was kept from before an edit (measured rows, rows not made again) is right.
        @Test func anySequenceOfEditsShowsWhatAFreshWindowShows() {
            let second = "\n| k | value |\n|---|:-:|\n| a | `code` and *more* |\n| b | 2 |\n| c | [ref] |\n\n[ref]: http://example.org\n"
            let w = window(sample + "\n" + second)
            defer { w.close() }
            var seed: UInt64 = 20261115
            func random(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(max(bound, 1)))
            }
            let pieces = ["a", "W", "i", " ", "**", "`", "|", "\n", "[x](y)", "wide wide", "| p | q |\n", "3", "*", "[ref]", ":"]
            for step in 0..<140 {
                let length = w.length
                switch random(10) {
                case 0...4:
                    w.textView.insertText(pieces[random(pieces.count)], replacementRange: NSRange(location: random(length + 1), length: 0))
                case 5, 6:
                    let start = random(length + 1)
                    w.textView.insertText("", replacementRange: NSRange(location: start, length: min(random(4) + 1, length - start)))
                case 7:
                    let start = random(length + 1), count = min(random(3) + 1, length - start)
                    w.textView.insertText(String(repeating: "W", count: count), replacementRange: NSRange(location: start, length: count))
                case 8:
                    w.select(random(length + 1), length: random(3) == 0 ? min(random(30), length) : 0)
                default:
                    w.textView.undoManager?.undo()
                }
                w.pump(0.002)
                let fresh = EditorWindow(w.textView.string)
                defer { fresh.close() }
                fresh.textView.setSelectedRange(w.textView.selectedRange())
                fresh.pump(0.002)
                guard fresh.textView.selectedRange() == w.textView.selectedRange() else { continue }
                let map = map(w)
                for table in map.tables {
                    for index in table.lines where map.lines[index].range.length > 0 {
                        let at = map.lines[index].range.location
                        let shown = w.displayParagraph(at: at).text, expected = fresh.displayParagraph(at: at).text
                        #expect(shown.isEqual(to: expected), "step \(step), line \(index) of \(w.textView.string.debugDescription)")
                        if !shown.isEqual(to: expected) { return }
                    }
                }
                #expect(w.storageProblem == nil)
            }
        }

        @Test func cellsOfEmojiAndCJKTextAreMeasuredAsDisplayed() {
            let source = "| 名前 | 🎉🎉🎉 | e\u{301}tat |\n|---:|:--:|---|\n| 東京都渋谷区 | 👨‍👩‍👧‍👦 family | ｆｕｌｌ |\n| a | **太字** | 한국어 텍스트 |\n"
            let w = window(source)
            defer { w.close() }
            #expect(spread(w) <= 0.5)
            #expect(spilled(w) == nil)
            let row = gridRow(w, at: 0)
            let wide = referenceWidth(NSAttributedString(string: " 東京都渋谷区 ", attributes: [.font: theme.bodyFont]))
            #expect(abs(((row?.edges[1] ?? 0) - (row?.edges[0] ?? 0)) - (wide.rounded(.up) + 2 * theme.tableCellPadding.width)) < 0.01)
        }

        @Test func tabsAndBlanksInARowDoNotMoveItsCellsOffTheirStops() throws {
            let source = "   | a | b |\n   |---|---|\n   | with\ta tab | d |   \n|\t\tx|y|\n"
            let w = window(source + "\nend")
            defer { w.close() }
            #expect(map(w).tables.map(\.lines) == [0..<4])
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            let row = try #require(gridRow(w, at: offset("with", in: w)))
            #expect(abs(w.columnX(at: offset("with", in: w) - 1) - row.edges[0] - theme.tableCellPadding.width) < 0.5)
            #expect(abs(w.columnX(at: offset("d |", in: w) - 1) - row.edges[1] - theme.tableCellPadding.width) < 0.5)
            #expect(abs(w.columnX(at: offset("y|", in: w)) - row.edges[1] - theme.tableCellPadding.width) < 0.5)
            #expect(w.displayParagraph(at: offset("with", in: w)).text.string.contains("with a tab"), "a tab in a cell shows as a space")
            #expect(w.textView.string == source + "\nend" && w.storageProblem == nil)
        }

        @Test func theGridIsDrawnWithHairlinesAHeaderFillAndRoundedCorners() throws {
            let w = window("| a | b |\n|---|---|\n| c | d |\n| e | f |\n| g | h |\n")
            defer { w.close() }
            let rows = ["| a", "| c", "| e", "| g"].map { offset($0, in: w) }
            let rects = try rows.map { row in
                w.inColumn(try #require((w.fragment(at: row) as? BlockFragment)?.tableRowRect), ofFragmentAt: row)
            }
            let decorations = try rows.map { try #require(gridRow(w, at: $0)) }
            #expect(decorations.map(\.isHeader) == [true, false, false, false])
            #expect(decorations.map(\.isLast) == [false, false, false, true])
            #expect(decorations.map(\.isStriped) == [false, false, true, false])
            #expect(Set(decorations.map(\.edges)).count == 1)
            // Rows meet without a gap wider than the hidden delimiter row.
            for (upper, lower) in zip(rects, rects.dropFirst()) { #expect(abs(upper.maxY - lower.minY) < 0.05) }
            #expect(rects.allSatisfy { $0.minX == 0 && $0.width == decorations[0].edges[2] })

            let (isBackground, _) = w.pixels()
            let header = rects[0], body = rects[1], last = rects[3], edge = decorations[0].edges[1]
            #expect(!isBackground(header.minX + 4, header.midY), "the header is tinted")
            #expect(isBackground(body.minX + 4, body.midY), "a plain row is not")
            #expect(!isBackground(rects[2].minX + 4, rects[2].midY), "a striped row is, slightly")
            #expect(!isBackground(header.minX + 0.5, header.midY) && !isBackground(body.maxX - 0.5, body.midY), "the outer border")
            #expect(!isBackground(header.midX, header.minY + 0.5) && !isBackground(last.midX, last.maxY - 0.5))
            #expect(!isBackground(edge + 0.5, body.midY) && isBackground(edge + 3, body.midY), "a column line")
            #expect(!isBackground(body.minX + 4, body.maxY - 0.5), "a row line")
            #expect(isBackground(header.minX + 0.5, header.minY + 0.5) && isBackground(last.maxX - 0.5, last.maxY - 0.5), "rounded corners")
            #expect(isBackground(header.minX - 2, header.midY) && isBackground(header.maxX + 2, header.midY))
        }

        @Test func aTableWithoutRowsIsAClosedHeader() throws {
            let w = window("| a | b |\n|---|---|\n\nend")
            defer { w.close() }
            let row = try #require(gridRow(w, at: 0))
            #expect(row.isHeader && row.isLast)
            #expect(spilled(w) == nil)
        }

        // MARK: too wide for single lines

        @Test func narrowingTheWindowWrapsTheCellsOfAWideTableAndBack() throws {
            let source = sample.replacingOccurrences(of: "plain", with: "plain and quite a bit longer than that")
            let w = window(source, size: NSSize(width: 900, height: 600))
            defer { w.close() }
            let header = offset("| Name", in: w), delimiter = offset("|:-----", in: w), body = offset("| kiwi", in: w)
            #expect(gridRow(w, at: header)?.cellStarts == [])
            let single = w.fragment(at: body).layoutFragmentFrame.height
            w.window.setContentSize(NSSize(width: 380, height: 600))
            w.pump()
            for row in [header, body] {
                let grid = try #require(gridRow(w, at: row))
                #expect(grid.cellStarts.count == 3 && grid.edges.last! <= w.textView.columnWidth, "a grid still, as wide as the text column")
                let style = try #require(w.displayAttributes(at: row)[.paragraphStyle] as? NSParagraphStyle)
                #expect(style.lineBreakMode == .byWordWrapping && style.tailIndent > 0, "lines that wrap, in their column")
            }
            #expect(w.displayFont(at: header + 2) == theme.tableHeaderFont)
            #expect(w.isHidden(delimiter) && w.fragment(at: delimiter).layoutFragmentFrame.height < 0.1, "the delimiter row stays hidden")
            let long = w.fragment(at: offset("| apple", in: w))
            #expect(long.layoutFragmentFrame.height > single + theme.bodyLineHeight - 1, "the long cell takes more than one line")
            #expect((long as? BlockFragment)?.fitsItsCells == true)
            #expect(spilled(w) == nil)
            w.window.setContentSize(NSSize(width: 900, height: 600))
            w.pump()
            #expect(gridRow(w, at: header)?.cellStarts == [] && gridRow(w, at: body)?.cellStarts == [])
            #expect(w.isHidden(delimiter) && spread(w) <= 0.5)
            #expect(w.textView.string == source && w.storageProblem == nil)
        }

        @Test func aTableThatGrowsTooWideWhileTypingWrapsItsCellsAndUndoAndRedoFollow() {
            let w = window(sample, size: NSSize(width: 620, height: 600))
            defer { w.close() }
            let header = offset("| Name", in: w)
            #expect(gridRow(w, at: header)?.cellStarts == [])
            w.select(offset("plain", in: w) + 5)
            w.type(String(repeating: " wider", count: 14))
            w.pump()
            #expect(gridRow(w, at: header)?.cellStarts.count == 3 && gridRow(w, at: offset("| kiwi", in: w))?.cellStarts.count == 3)
            #expect(spilled(w) == nil)
            // Still a grid to the keys: Tab goes to the next cell and a pipe is escaped.
            w.type("\t")
            #expect(place(w) == (5, 0))
            w.type("|")
            let typed = w.textView.string
            #expect(typed.contains("| \\| |") && map(w).lines[5].cells.count == 3)
            w.undoAll()
            #expect(w.textView.string == sample)
            #expect(gridRow(w, at: header)?.cellStarts == [] && spread(w) <= 0.5)
            while w.textView.undoManager?.canRedo == true { w.textView.undoManager?.redo() }
            w.pump()
            #expect(w.textView.string == typed && gridRow(w, at: header)?.cellStarts.count == 3 && w.storageProblem == nil)
        }

        @Test func tablesThatAreNotRegularShowAsSource() {
            let sources = ["Name | Value\n--- | ---\none | 1\n", "| a | b |\n|---|---|\n| c | d | extra |\n", "| a | b |\n--- | ---\n| c | d |\n",
                           "| a | b |\n|---|---|\n| c | d |\ntext right below\n"]
            for source in sources {
                let w = window(source + "\nend")
                defer { w.close() }
                #expect(map(w).tables.count == 1)
                #expect(spilled(w) == nil, "\(source)")
                #expect(gridRow(w, at: 0) == nil, "\(source)")
                #expect(!w.isHidden((source as NSString).range(of: "---").location), "\(source)")
                #expect(w.displayParagraph(at: 0).text.string == (source as NSString).substring(to: (source as NSString).range(of: "\n").location + 1))
            }
        }

        // MARK: containers and line endings

        @Test func tablesInQuotesAndListsAreGridsAtTheirIndent() throws {
            let source = "> | a | b |\n> |---|--:|\n> | c | d |\n\n- item\n\n  | e | f |\n  |---|---|\n  | g | h |\n\n1. | i | j |\n   |---|---|\n   | k | l |\n"
            let w = window(source + "\nend")
            defer { w.close() }
            #expect(spilled(w) == nil)
            let quoted = try #require(gridRow(w, at: 0)), listed = try #require(gridRow(w, at: offset("| e", in: w)))
            let marked = try #require(gridRow(w, at: offset("1.", in: w)))
            #expect(quoted.edges[0] == theme.quoteIndent && listed.edges[0] == theme.listIndent && marked.edges[0] == theme.listIndent)
            #expect(gridRow(w, at: offset("> | c", in: w))?.edges == quoted.edges)
            #expect(gridRow(w, at: offset("   | k", in: w))?.edges == marked.edges)
            let padding = theme.tableCellPadding.width
            #expect(abs(w.columnX(at: offset("a |", in: w) - 1) - quoted.edges[0] - padding) < 0.5)
            #expect(abs(columnMaxX(w, at: offset("d |", in: w) + 1) - quoted.edges[2] + padding) < 0.5, "right-aligned")
            #expect(abs(w.columnX(at: offset("g |", in: w) - 1) - listed.edges[0] - padding) < 0.5)
            #expect(abs(w.columnX(at: offset("i |", in: w) - 1) - marked.edges[0] - padding) < 0.5)
            #expect(w.columnX(at: offset("1.", in: w)) < theme.listIndent, "the number stays left of the grid")
            #expect((w.fragment(at: 0) as? BlockFragment)?.quoteBarRects.count == 1)
            #expect(w.isHidden(0) && w.isHidden(offset("> | c", in: w)), "quote markers stay hidden")
            #expect(w.fragment(at: offset("> |---", in: w)).layoutFragmentFrame.height <= 0.02)
            #expect(w.textView.string == source + "\nend" && w.storageProblem == nil)
        }

        @Test func tablesWithCRLFLineEndingsRenderAndEditTheSame() {
            let source = sample.replacingOccurrences(of: "\n", with: "\r\n")
            let w = window(source)
            defer { w.close() }
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            #expect(w.fragment(at: offset("|:-----", in: w)).layoutFragmentFrame.height <= 0.02)
            w.select(offset("x |", in: w))
            w.type("\tnew")
            #expect(w.textView.string.contains("| x |\r\n| new"))
            #expect(!w.textView.string.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            w.undoAll()
            #expect(w.textView.string == source)
        }

        // MARK: selection

        @Test func arrowKeysStepOverTheDelimiterRow() {
            let w = window(sample)
            defer { w.close() }
            // The stops beside it: in front of the pipe that closes the header, and behind the first row's leading pipe.
            let delimiter = offset("|:-----", in: w), below = offset("| apple", in: w) + 1, above = delimiter - 2
            w.select(offset("| Name", in: w))
            #expect(w.textView.selectedRange().location == offset("| Name", in: w) + 1)
            var visited: [Int] = []
            for _ in 0..<30 {
                w.command(#selector(NSResponder.moveRight(_:)))
                visited.append(w.textView.selectedRange().location)
            }
            #expect(!visited.contains { (above + 1..<below).contains($0) })
            #expect(visited.contains(above) && visited.contains(below))
            #expect(zip(visited, visited.dropFirst()).allSatisfy { $1 == $0 + 1 || ($0 == above && $1 == below) })
            visited = []
            for _ in 0..<30 {
                w.command(#selector(NSResponder.moveLeft(_:)))
                visited.append(w.textView.selectedRange().location)
            }
            #expect(!visited.contains { (above + 1..<below).contains($0) })
            #expect(zip(visited, visited.dropFirst()).allSatisfy { $1 == $0 - 1 || ($0 == below && $1 == above) })
            #expect(visited.last == offset("| Name", in: w) + 1)
            // Programmatic and clicked selections cannot rest there either.
            w.select(offset("intro", in: w))
            w.select(delimiter + 3)
            #expect(w.textView.selectedRange() == NSRange(location: below, length: 0))
            w.select(w.length)
            w.select(delimiter + 3)
            #expect(w.textView.selectedRange() == NSRange(location: above, length: 0))
        }

        @Test func upAndDownKeepTheColumnAcrossTheDelimiterRow() {
            let w = window(sample)
            defer { w.close() }
            func column() -> Int {
                let caret = w.textView.selectedRange().location, map = map(w)
                return map.lines[map.lineIndex(containing: caret)!].pipes.count { $0 < caret } - 1
            }
            func line() -> Int { map(w).lineIndex(containing: w.textView.selectedRange().location)! }
            for (name, expected) in [("Name", 0), ("Qty", 1), ("Note", 2)] {
                w.select(offset(name, in: w) + 1)
                let x = w.characterRect(at: offset(name, in: w) + 1).minX
                w.command(#selector(NSResponder.moveDown(_:)))
                #expect(line() == 4 && column() == expected, "down from \(name)")
                #expect(abs(w.characterRect(at: w.textView.selectedRange().location).minX - x) < 20)
                w.command(#selector(NSResponder.moveDown(_:)))
                #expect(line() == 5 && column() == expected)
                w.command(#selector(NSResponder.moveUp(_:)))
                w.command(#selector(NSResponder.moveUp(_:)))
                #expect(line() == 2 && column() == expected, "up to \(name)")
                w.command(#selector(NSResponder.moveUp(_:)))
                #expect(line() < 2, "and out of the table")
            }
        }

        @Test func aSelectionTakesTheDelimiterRowWholeOrNotAtAll() {
            let w = window(sample)
            defer { w.close() }
            let delimiter = offset("|:-----", in: w), below = offset("| apple", in: w), above = delimiter - 1
            w.select(above - 2)
            w.select(above - 2, length: 5)
            #expect(w.textView.selectedRange() == NSRange(location: above - 2, length: below - above + 2))
            w.select(below + 3)
            w.select(delimiter + 2, length: below + 3 - delimiter - 2)
            #expect(w.textView.selectedRange() == NSRange(location: above, length: below + 3 - above))
            // Extending by keys.
            w.select(above)
            #expect(w.textView.selectedRange() == NSRange(location: above - 1, length: 0), "a caret stays in front of the closing pipe")
            w.command(#selector(NSResponder.moveRightAndModifySelection(_:)))
            w.command(#selector(NSResponder.moveRightAndModifySelection(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: above - 1, length: below - above + 1))
            w.command(#selector(NSResponder.moveLeftAndModifySelection(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: above - 1, length: 1))
            w.command(#selector(NSResponder.selectAll(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 0, length: w.length))
        }

        /// The column of the first table that the caret is in, and the line.
        private func place(_ w: EditorWindow) -> (line: Int, column: Int) {
            let caret = w.textView.selectedRange().location, map = map(w), line = map.lineIndex(containing: caret)!
            return (line, map.lines[line].pipes.count { $0 < caret } - 1)
        }

        private func isWholeGrid(_ w: EditorWindow) -> Bool {
            let map = map(w)
            return map.tables.count == 1 && map.isRegular(map.tables[0]) && gridRow(w, at: map.lines[map.tables[0].lines.lowerBound].range.location) != nil
                && spilled(w) == nil
        }

        @Test func theCaretStaysInsideTheOuterPipesOfARow() {
            let w = window(sample)
            defer { w.close() }
            for cell in ["Name", "apple", "kiwi"] {
                let start = offset("| " + cell, in: w)
                var end = 0
                (sample as NSString).getLineStart(nil, end: nil, contentsEnd: &end, for: NSRange(location: start, length: 0))
                w.select(start + 4)
                w.command(#selector(NSResponder.moveToBeginningOfLine(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: start + 1, length: 0), "Home in \(cell)")
                w.type("x")
                #expect(w.textView.string.contains("|x \(cell)") && isWholeGrid(w))
                w.command(#selector(NSResponder.moveToEndOfLine(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: end, length: 0), "End stops in front of the closing pipe")
                w.type("y|")
                #expect((w.textView.string as NSString).substring(with: NSRange(location: end, length: 5)) == "y\\||\n" && isWholeGrid(w))
                w.undoAll()
                #expect(w.textView.string == sample)
                // Set there, or clicked beside the row.
                for location in [start, end] {
                    w.select(location)
                    #expect(w.textView.selectedRange() == NSRange(location: location == start ? start + 1 : end - 1, length: 0))
                }
                let row = w.characterRect(at: start + 2), origin = w.textView.textContainerOrigin.x
                w.placeCaret(at: NSPoint(x: origin - 20, y: row.midY))
                #expect(w.textView.selectedRange() == NSRange(location: start + 1, length: 0), "a click left of the row")
                w.placeCaret(at: NSPoint(x: origin + 700, y: row.midY))
                #expect(w.textView.selectedRange() == NSRange(location: end - 1, length: 0), "a click right of the row")
            }
            // Rightwards from the last cell's end the next stop is the line below; leftwards it comes back.
            let last = offset("\n\nend", in: w) - 1
            w.select(last)
            w.command(#selector(NSResponder.moveRight(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: last + 2, length: 0))
            w.command(#selector(NSResponder.moveLeft(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: last, length: 0))
            #expect(w.textView.undoManager?.canUndo == false)
        }

        @Test func returnAtTheStartOfATableThatStartsTheTextOpensALineAbove() {
            let table = "| a | b |\n|---|---|\n| c | d |"
            let w = window(table)
            defer { w.close() }
            w.select(0)
            #expect(w.textView.selectedRange().location == 1)
            w.type("\rtop")
            #expect(w.textView.string == "top\n" + table)
            #expect(isWholeGrid(w))
            w.undoAll()
            #expect(w.textView.string == table)
        }

        @Test func revealingALinkNeverTurnsTheGridIntoSourceUnderTheCaret() {
            let w = window(sample)
            defer { w.close() }
            let header = offset("| Name", in: w), link = offset("[site]", in: w)
            let hidden = gridRow(w, at: header)!.edges.last!
            w.select(link + 2)
            w.pump()
            let revealed = gridRow(w, at: header)!.edges.last!
            #expect(revealed > hidden + 100, "the URL shows and widens its column")
            // A window whose room for the table lies between the two widths.
            w.select(w.length)
            w.window.setContentSize(NSSize(width: ((hidden + revealed) / 2).rounded() + 2 * theme.pagePadding.width, height: 600))
            w.pump()
            #expect(w.textView.textContainer!.size.width > hidden && w.textView.textContainer!.size.width < revealed)
            #expect(isWholeGrid(w))
            w.select(offset("**red**", in: w) + 3)
            w.type("\t")
            #expect(w.textView.selectedRange() == NSRange(location: link, length: 38), "Tab selects the link cell")
            #expect(gridRow(w, at: header) != nil && w.fragment(at: offset("|:-----", in: w)).layoutFragmentFrame.height <= 0.02, "which stays a grid")
            w.type("\t")
            #expect(w.textView.string == sample, "and the next Tab moves on instead of replacing the cell")
            #expect(w.textView.selectedRange() == NSRange(location: offset("| 1 |", in: w) + 2, length: 1))
            w.select(link + 2)
            w.command(#selector(NSResponder.moveUp(_:)))
            #expect(place(w) == (6, 0), "Up from the revealed link is the cell above")
        }

        /// With wrapping switched off, which is what is left should a system break it: a table
        /// too wide for the window shows as source, as it did before cells could wrap.
        @Test func aCaretInTheDelimiterRowLeavesItWhenTheTableBecomesAGrid() {
            ParagraphRenderer.wrapsWideTables = false
            defer { ParagraphRenderer.wrapsWideTables = true }
            let source = sample.replacingOccurrences(of: "plain", with: "plain and quite a bit longer than that, and then some more")
            let w = window(source, size: NSSize(width: 380, height: 600))
            defer { w.close() }
            let header = offset("| Name", in: w), delimiter = offset("|:-----", in: w)
            #expect(gridRow(w, at: header) == nil)
            w.select(delimiter + 3)
            #expect(w.textView.selectedRange().location == delimiter + 3, "in source the delimiter row is text")
            w.window.setContentSize(NSSize(width: 900, height: 600))
            w.pump()
            #expect(gridRow(w, at: header) != nil)
            #expect(w.textView.selectedRange() == NSRange(location: offset("| apple", in: w) + 1, length: 0))
            w.type("z")
            #expect(isWholeGrid(w) && w.textView.string.contains("|z apple"))
        }

        @Test func aClickInTheEmptyPartOfACellStaysInItsColumn() throws {
            let sources = ["| a long header here for some width | b | c |\n|---|---|--:|\n| x | y | z |\n| a much longer cell than the others, really | y2 | a wide right column |\n\nend",
                           "| left | a wide centred column here | right |\n|---|:-:|---|\n| x | y | z |\n\nend"]
            for source in sources {
                let w = window(source)
                defer { w.close() }
                let row = offset("| x | y | z |", in: w), edges = try #require(gridRow(w, at: row)).edges
                let y = w.characterRect(at: row + 2).midY, origin = w.textView.columnLeft
                for column in 0..<3 {
                    for fraction in [0.03, 0.2, 0.5, 0.6, 0.8, 0.97] {
                        w.placeCaret(at: NSPoint(x: origin + edges[column] + fraction * (edges[column + 1] - edges[column]), y: y))
                        #expect(place(w) == (2, column), "column \(column) at \(fraction)")
                    }
                }
                #expect(w.textView.string == source)
            }
        }

        @Test func upAndDownKeepTheColumnWhateverTheCellsHold() {
            let source = "| a long header here for some width | b | c |\n|---|---|--:|\n| x | y | z |\n| a much longer cell than the others, really | y2 | a wide right column |\n| p | q | r |\n\nend"
            let w = window(source)
            defer { w.close() }
            w.select(offset("really", in: w) + 6)
            w.command(#selector(NSResponder.moveUp(_:)))
            #expect(place(w) == (2, 0))
            w.select(offset("really", in: w) + 6)
            w.command(#selector(NSResponder.moveDown(_:)))
            #expect(place(w) == (4, 0))
            w.select(offset("a wide right", in: w))
            w.command(#selector(NSResponder.moveDown(_:)))
            #expect(place(w) == (4, 2))
            w.command(#selector(NSResponder.moveUp(_:)))
            w.command(#selector(NSResponder.moveUp(_:)))
            w.command(#selector(NSResponder.moveUp(_:)))
            #expect(place(w) == (0, 2), "over the delimiter row into the header")
        }

        @Test func upAndDownFromASelectedCellKeepTheColumn() {
            let w = window(sample)
            defer { w.close() }
            w.select(offset("Note", in: w) + 1)
            w.type("\t")
            #expect(w.textView.selectedRange() == NSRange(location: offset("apple", in: w), length: 5))
            w.command(#selector(NSResponder.moveUp(_:)))
            #expect(place(w) == (2, 0) && w.textView.selectedRange().length == 0, "Up from the cell Tab selected")
            w.select(offset("Qty", in: w), length: 3)
            w.command(#selector(NSResponder.moveDown(_:)))
            #expect(place(w) == (4, 1))
            w.select(offset("| 3 |", in: w) + 2, length: 1)
            w.command(#selector(NSResponder.moveUp(_:)))
            #expect(place(w) == (2, 1))
        }

        @Test func backspaceAndDeleteKeepTheBlankLineBelowATable() {
            let source = "| a | b |\n|---|---|\n| c | d |\n\nend"
            let w = window(source)
            defer { w.close() }
            let blank = offset("\n\nend", in: w) + 1
            for command in [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
                            #selector(NSResponder.deleteToBeginningOfLine(_:))] {
                w.select(blank)
                w.command(command)
                #expect(w.textView.string == source && w.textView.selectedRange() == NSRange(location: blank - 2, length: 0), "\(command)")
            }
            for command in [#selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:))] {
                w.select(blank)
                w.command(command)
                #expect(w.textView.string == source && w.textView.selectedRange() == NSRange(location: blank, length: 0), "\(command)")
            }
            #expect(isWholeGrid(w) && w.textView.undoManager?.canUndo == false)
        }

        // MARK: room

        private let wide = """
            A paragraph that is long enough to wrap in any window, so that where its lines end can be compared with the column: \
            lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.

            | Option | Description | Default | Since | Deprecated | Replacement option name |
            |--------|-------------|---------|-------|------------|-------------------------|
            | `maximumTextWidth` | The widest the text column may be | `780` | 1.0 | no | none |
            | `pagePadding` | Least space between text and the window | `44` | 1.0 | 2.0 | `pageInsets` |

            end
            """

        @Test func aTableTooWideAtTheNormalSizeIsACompactGrid() throws {
            let source = "| Left aligned | Centred column | Right aligned |\n|:--|:-:|--:|\n| banana split with cream | some more text | 1,234.50 |\n\nend"
            let w = window(source, size: NSSize(width: 520, height: 600))
            defer { w.close() }
            let room = w.textView.textContainer!.size.width
            #expect(try #require(gridRow(w, at: 0)).edges.last! <= room)
            #expect(w.displayFont(at: offset("banana", in: w)) == theme.tableFont(isHeader: false, isCompact: true))
            #expect(w.displayFont(at: 2) == theme.tableFont(isHeader: true, isCompact: true))
            #expect(spilled(w) == nil)
            w.window.setContentSize(NSSize(width: 900, height: 600))
            w.pump()
            #expect(w.displayFont(at: offset("banana", in: w)).pointSize == theme.bodySize && spread(w) <= 0.5, "at its normal size where that fits")
        }

        @Test func inAWideWindowAGridMayPassTheColumnAndTextDoesNot() throws {
            let w = window(wide, size: NSSize(width: 1600, height: 700))
            defer { w.close() }
            let column = w.textView.columnWidth, room = w.textView.textContainer!.size.width
            let view = w.textView.frame.width
            #expect(column == theme.maximumTextWidth && room == view - 2 * theme.pagePadding.width, "the page between its paddings")
            let header = offset("| Option", in: w), edges = try #require(gridRow(w, at: header)).edges
            #expect(edges.last! > column && edges[0] < 0 && edges.last! - edges[0] <= room, "the grid uses the page's margins")
            #expect(abs(edges[0] + edges.last! - column) <= 1, "and stands in the middle of the page")
            // The caret and a click reach the cells beside the column, on either side.
            let left = offset("`pagePadding`", in: w) + 3, right = offset("`pageInsets`", in: w) + 10
            #expect(w.columnX(at: left) < 0)
            for cell in [left, right] {
                let rect = w.characterRect(at: cell)
                w.placeCaret(at: NSPoint(x: rect.minX + 1, y: rect.midY))
                #expect(w.textView.selectedRange() == NSRange(location: cell, length: 0))
            }
            // Text keeps to the column, and so does what is drawn for it.
            let paragraph = w.fragment(at: 0)
            #expect(paragraph.textLineFragments.count > 1)
            #expect(paragraph.textLineFragments.map { w.inColumn($0.typographicBounds, ofFragmentAt: 0) }.allSatisfy { $0.minX >= 0 && $0.maxX <= column + 0.5 })
            // Narrower, the page has not the room: the table is as wide as the page and its cells wrap.
            w.window.setContentSize(NSSize(width: 880, height: 700))
            w.pump()
            let narrow = try #require(gridRow(w, at: header)), page = w.textView.textContainer!.size.width
            #expect(!narrow.cellStarts.isEmpty && narrow.edges.last! - narrow.edges[0] <= page && narrow.edges.last! - narrow.edges[0] > page - 8)
            #expect(w.fragment(at: 0).textLineFragments.map { w.inColumn($0.typographicBounds, ofFragmentAt: 0) }.allSatisfy { $0.minX >= 0 && $0.maxX <= w.textView.columnWidth + 0.5 })
            #expect(w.textView.string == wide && w.storageProblem == nil)
        }

        @Test func aSelectionEndsAtTheGridAndAtTheColumn() throws {
            let w = window(wide, size: NSSize(width: 1600, height: 700))
            defer { w.close() }
            w.window.makeKey()
            w.textView.setSelectedRange(NSRange(location: 0, length: w.length))
            w.pump()
            let column = w.textView.columnWidth, header = offset("| Option", in: w)
            let edges = try #require(gridRow(w, at: header)).edges, left = edges[0], right = edges.last!
            let pixels = w.pixels()
            let paragraph = w.fragment(at: 0).layoutFragmentFrame, row = w.fragment(at: offset("| `pagePadding`", in: w)).layoutFragmentFrame
            #expect(!pixels.isBackground(column - 4, paragraph.midY), "selected to the end of the column")
            #expect(pixels.isBackground(column + 4, paragraph.midY), "and not beyond it")
            #expect(pixels.isBackground(-4, paragraph.midY) && pixels.isBackground(left - 4, row.midY), "nor in front of it or of the grid")
            #expect(!pixels.isBackground(right - 4, row.midY) && !pixels.isBackground(column + 4, row.midY), "a grid row to the grid's edge")
            #expect(pixels.isBackground(right + 4, row.midY))
            // The row is selected from border to border.
            #expect(!pixels.isBackground(left + 20, row.minY + 2) && !pixels.isBackground(left + 20, row.maxY - 2))
        }

        @Test func aTableShownAsSourceIsSetLikeCode() throws {
            // Wrapping switched off: the table is too wide for the window and shows as source.
            ParagraphRenderer.wrapsWideTables = false
            defer { ParagraphRenderer.wrapsWideTables = true }
            let w = window(wide, size: NSSize(width: 600, height: 700))
            defer { w.close() }
            let header = offset("| Option", in: w), delimiter = offset("|-----", in: w), last = offset("| `pagePadding`", in: w)
            #expect(gridRow(w, at: header) == nil)
            for line in [header, delimiter, last] {
                #expect(w.displayFont(at: line + 3) == theme.codeFont(size: theme.codeBlockFontSize))
                let panel = try #require(w.fragment(at: line) as? BlockFragment).codePanelRect
                #expect(panel != nil, "a panel behind every line")
            }
            #expect(w.displayAttributes(at: header)[.foregroundColor] as? NSColor == theme.marker, "pipes are dimmed")
            #expect(w.displayAttributes(at: header + 2)[.foregroundColor] as? NSColor == theme.text)
            let code = offset("`maximumTextWidth`", in: w)
            #expect(w.displayAttributes(at: code + 2)[.inlineBackground] == nil && w.displayFont(at: code).pointSize > 1, "the source as it is")
            #expect((w.fragment(at: header) as? BlockFragment)?.codePanelRect?.minY ?? 0 < w.fragment(at: header).textLineFragments[0].typographicBounds.minY)
        }

        // MARK: keys

        @Test func tabAndShiftTabSelectCellsAndTabInTheLastCellAppendsARow() {
            let w = window("| a | b |\n|---|---|\n| c | d |\n\nend")
            defer { w.close() }
            w.select(offset("a |", in: w))
            w.type("\t")
            #expect(w.textView.selectedRange() == NSRange(location: offset("b |", in: w), length: 1))
            w.type("\t")
            #expect(w.textView.selectedRange() == NSRange(location: offset("c |", in: w), length: 1), "over the delimiter row")
            w.type(String(EditorWindow.backtab))
            #expect(w.textView.selectedRange() == NSRange(location: offset("b |", in: w), length: 1))
            w.type("\t\t\t")
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n|  |  |\n\nend")
            #expect(w.textView.selectedRange() == NSRange(location: offset("|  |", in: w) + 2, length: 0))
            w.type("x\ty")
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n| x | y |\n\nend")
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            w.textView.undoManager?.undo()
            w.textView.undoManager?.undo()
            w.textView.undoManager?.undo()
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n\nend", "the appended row is one undo step")
            w.textView.undoManager?.redo()
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n|  |  |\n\nend")
            #expect(w.storageProblem == nil)
        }

        @Test func returnMovesDownAppendsARowAndLeavesFromAnEmptyOne() {
            let w = window("| a | b |\n|---|---|\n| c | d |\n\nend")
            defer { w.close() }
            w.select(offset("b |", in: w) + 1)
            w.type("\r")
            #expect(w.textView.selectedRange() == NSRange(location: offset("d |", in: w), length: 1))
            w.type("\r")
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n|  |  |\n\nend")
            #expect(w.textView.selectedRange() == NSRange(location: offset("|  |", in: w) + 5, length: 0), "the same column")
            #expect(spilled(w) == nil)
            w.type("\r")
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n\n\n\nend")
            #expect(w.textView.selectedRange() == NSRange(location: offset("\n\n\n", in: w) + 2, length: 0))
            w.type("after")
            #expect(map(w).tables.map(\.lines) == [0..<3] && spilled(w) == nil)
            w.undoAll()
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n\nend")
            w.textView.undoManager?.redo()
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n|  |  |\n\nend", "redo brings the row back")
            w.textView.undoManager?.redo()
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n\n\n\nend", "and leaves the table again")
            w.pump()
            #expect(spread(w) <= 0.5 && spilled(w) == nil && w.storageProblem == nil)
        }

        @Test func aTypedPipeIsEscapedAndKeepsTheColumnCount() {
            let w = window(sample)
            defer { w.close() }
            w.select(offset("kiwi", in: w) + 2)
            w.type("|")
            #expect(w.textView.string.contains("| ki\\|wi | 7 |"))
            #expect(w.textView.selectedRange().location == offset("wi | 7", in: w))
            #expect(map(w).lines[6].cells.count == 3)
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            w.textView.undoManager?.undo()
            #expect(w.textView.string == sample)
            w.textView.undoManager?.redo()
            #expect(w.textView.string.contains("| ki\\|wi | 7 |"))
            // Outside a table a pipe is a pipe.
            w.select(offset("intro", in: w))
            w.type("|")
            #expect(w.textView.string.hasPrefix("|intro"))
        }

        @Test func backspaceAtARowStartAndDeleteAtARowEndDoNothing() {
            let w = window(sample)
            defer { w.close() }
            let backward = [#selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteWordBackward(_:)),
                            #selector(NSResponder.deleteToBeginningOfLine(_:))]
            let forward = [#selector(NSResponder.deleteForward(_:)), #selector(NSResponder.deleteWordForward(_:)),
                           #selector(NSResponder.deleteToEndOfLine(_:))]
            for start in [offset("| apple", in: w) + 1, offset("| kiwi", in: w) + 1, offset("| 7", in: w) + 1] {
                for command in backward {
                    w.select(start)
                    w.command(command)
                    #expect(w.textView.string == sample && w.textView.selectedRange().location == start, "\(command) at \(start)")
                }
            }
            for end in [offset("\n| a **bold", in: w) - 1, offset("| 3 |", in: w), offset("\n\nend", in: w) - 1, offset("|\n|:--", in: w)] {
                for command in forward {
                    w.select(end)
                    w.command(command)
                    #expect(w.textView.string == sample && w.textView.selectedRange().location == end, "\(command) at \(end)")
                }
            }
            #expect(w.textView.undoManager?.canUndo == false, "nothing was registered")
            // Inside a cell the keys delete.
            w.select(offset("apple", in: w) + 5)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string.contains("| appl | 3 |"))
        }

        @Test func aHeaderRowAndReturnMakeATable() {
            let w = window("intro\n\n")
            defer { w.close() }
            w.type("|a|b|\r")
            #expect(w.textView.string == "intro\n\n|a|b|\n|---|---|\n|  |  |")
            #expect(w.textView.selectedRange() == NSRange(location: offset("|  |", in: w) + 2, length: 0))
            #expect(gridRow(w, at: offset("|a|b|", in: w))?.isHeader == true)
            w.type("x\ty")
            #expect(w.textView.string == "intro\n\n|a|b|\n|---|---|\n| x | y |")
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
            while w.textView.string.contains("---"), w.textView.undoManager?.canUndo == true { w.textView.undoManager?.undo() }
            #expect(w.textView.string == "intro\n\n|a|b|", "the rows go in one undo step")
            w.textView.undoManager?.redo()
            #expect(w.textView.string == "intro\n\n|a|b|\n|---|---|\n|  |  |")
        }

        @Test func textTypedDirectlyBelowATableStaysOutOfIt() {
            let w = window("| a | b |\n|---|---|\n| c | d |\n")
            defer { w.close() }
            w.type("below")
            #expect(w.textView.string == "| a | b |\n|---|---|\n| c | d |\n\nbelow")
            #expect(map(w).tables.map(\.lines) == [0..<3] && gridRow(w, at: 0) != nil)
        }

        // MARK: paste and range delete

        @Test func pasteAndRangeDeleteAcrossRowsNeverSpillTheGrid() {
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let pastes = ["x", "one | two", "a\nb", "| p | q |\n| r | s |", "| p | q | r | s |", "plain\n\ntext", "|", "\n", "|---|"]
            let ranges = [("apple", "12"), ("Qty", "plain"), ("| Name", "| apple"), ("|:--", "| a **"), ("Note |", "|:-"), ("7 |", "[site"),
                          ("intro", "kiwi"), ("x |", "end"), ("| kiwi", "| [site")]
            for (from, to) in ranges {
                for paste in [""] + pastes {
                    let w = window(sample)
                    defer { w.close() }
                    let start = offset(from, in: w), end = offset(to, in: w)
                    w.select(start, length: end - start)
                    // The delimiter row is taken whole, so the selection can be more than was asked for.
                    let selection = w.textView.selectedRange()
                    if paste.isEmpty {
                        w.command(#selector(NSResponder.deleteBackward(_:)))
                    } else {
                        pasteboard.clearContents()
                        pasteboard.setString(paste, forType: .string)
                        #expect(w.textView.readSelection(from: pasteboard, type: .string))
                    }
                    w.pump(0.01)
                    let expected = (sample as NSString).replacingCharacters(in: selection, with: paste)
                    #expect(w.textView.string == expected, "\(from)...\(to) with \(paste.debugDescription)")
                    #expect(spilled(w) == nil, "\(from)...\(to) with \(paste.debugDescription)")
                    let map = map(w)
                    if let table = map.tables.first, gridRow(w, at: map.lines[table.lines.lowerBound].range.location) != nil {
                        #expect(spread(w) <= 0.5, "\(from)...\(to) with \(paste.debugDescription)")
                    }
                    w.undoAll()
                    #expect(w.textView.string == sample)
                    #expect(spread(w) <= 0.5 && spilled(w) == nil, "after undoing \(from)...\(to) with \(paste.debugDescription)")
                    #expect(w.storageProblem == nil)
                }
            }
        }

        // MARK: commands

        private func item(_ title: String) -> NSMenuItem {
            EditorTextView.tableMenu().items.first { $0.title == title }!
        }

        @Test func everyTableCommandIsOneUndoStepAndRedoesExactly() {
            let source = "intro\n\n| a | b | c |\n|---|:-:|---|\n| d | e | f |\n| g | h | i |\n| j | k | l |\n\nend"
            var run: Set<String> = []
            for caret in ["h |", "g |"] {
                for title in EditorTextView.tableMenu().items.filter({ !$0.isSeparatorItem }).map(\.title) {
                    let w = window(source)
                    defer { w.close() }
                    w.select(offset(caret, in: w))
                    let item = item(title)
                    guard w.textView.validateUserInterfaceItem(item) else { continue }
                    run.insert(title)
                    w.textView.performTableCommand(item)
                    w.pump(0.01)
                    let edited = w.textView.string, selection = w.textView.selectedRange()
                    #expect(edited != source, "\(title)")
                    #expect(map(w).tables.count == 1 && spread(w) <= 0.5 && spilled(w) == nil, "\(title)")
                    #expect(gridRow(w, at: selection.location) != nil, "\(title): the caret stays in the grid")
                    w.textView.undoManager?.undo()
                    w.pump(0.01)
                    #expect(w.textView.string == source, "undo \(title)")
                    #expect(w.textView.undoManager?.canUndo == false, "\(title) is one step")
                    #expect(spread(w) <= 0.5 && spilled(w) == nil, "undo \(title)")
                    w.textView.undoManager?.redo()
                    w.pump(0.01)
                    #expect(w.textView.string == edited, "redo \(title)")
                    #expect(spread(w) <= 0.5 && spilled(w) == nil, "redo \(title)")
                    #expect(w.storageProblem == nil)
                }
            }
            #expect(run.count == TableCommand.allCases.count, "\(run)")
        }

        @Test func tableCommandsEditTheSource() {
            let w = window("| a | b |\n|---|---|\n| c | d |\n\nend")
            defer { w.close() }
            w.select(offset("d |", in: w))
            for title in ["Insert Row Above", "Insert Column Left", "Align Right", "Delete Row"] {
                w.textView.performTableCommand(item(title))
                w.pump(0.01)
            }
            #expect(w.textView.string == "| a |   | b |\n|---|--:|---|\n| c |   | d |\n\nend")
            #expect((w.displayAttributes(at: 0)[.paragraphStyle] as? NSParagraphStyle)?.tabStops.map(\.alignment) == [.left, .right, .left, .left])
            #expect(spread(w) <= 0.5 && spilled(w) == nil)
        }

        @Test func tableCommandsAreEnabledOnlyInATable() {
            let w = window(sample)
            defer { w.close() }
            let items = EditorTextView.tableMenu().items.filter { !$0.isSeparatorItem }
            #expect(items.count == TableCommand.allCases.count)
            #expect(items.allSatisfy { $0.action == #selector(EditorTextView.performTableCommand(_:)) })
            w.select(offset("intro", in: w))
            #expect(items.allSatisfy { !w.textView.validateUserInterfaceItem($0) })
            w.textView.performTableCommand(item("Insert Row Below"))
            #expect(w.textView.string == sample, "a command outside a table does nothing")
            w.select(offset("kiwi", in: w))
            #expect(items.filter { !w.textView.validateUserInterfaceItem($0) }.map(\.title) == ["Align Left"])
            w.select(offset("Name", in: w))
            #expect(items.filter { !w.textView.validateUserInterfaceItem($0) }.map(\.title) == ["Insert Row Above", "Delete Row", "Align Left"])
            // Other items are still the text view's own business.
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
            #expect(!w.textView.validateUserInterfaceItem(copy))
            w.select(offset("kiwi", in: w), length: 4)
            #expect(w.textView.validateUserInterfaceItem(copy))
        }

        @Test func theContextMenuOffersTheTableCommandsInsideATable() throws {
            let w = window(sample)
            defer { w.close() }
            func menu(at offset: Int) -> NSMenu? {
                w.select(offset)
                let rect = w.characterRect(at: offset)
                return w.textView.menu(for: NSEvent.mouseEvent(
                    with: .rightMouseDown, location: w.textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            let inside = try #require(menu(at: offset("kiwi", in: w) + 1))
            let table = try #require(inside.items.first?.submenu)
            #expect(inside.items.first?.title == "Table" && inside.items[1].isSeparatorItem)
            #expect(table.items.filter { !$0.isSeparatorItem }.count == TableCommand.allCases.count)
            #expect(inside.items.count > 2, "the text view's own items follow")
            let outside = try #require(menu(at: offset("intro", in: w) + 1))
            #expect(!outside.items.contains { $0.title == "Table" })
        }
    }
}
