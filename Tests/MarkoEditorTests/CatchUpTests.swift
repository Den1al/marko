import AppKit
import FixtureSupport
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// A change that restyles paragraphs far from the window (a table's columns, a width) asks
    /// TextKit again only for the paragraphs in the window; the others are asked for when the
    /// window comes to them. Whatever is on screen must be what a window that has only just
    /// loaded the same text shows, in the very frame it comes into view.
    @Suite struct CatchUpTests {
        /// The display paragraphs TextKit has laid out for the window, by their place in the
        /// text, as it has them: nothing here asks for one or brings one up to date.
        private func shown(_ w: EditorWindow) -> [(offset: Int, text: NSAttributedString)] {
            guard let viewport = w.layout.textViewportLayoutController.viewportRange else { return [] }
            var found: [(Int, NSAttributedString)] = []
            w.layout.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending,
                      let paragraph = fragment.textElement as? NSTextParagraph else { return false }
                found.append((w.content.offset(from: w.content.documentRange.location, to: fragment.rangeInElement.location), paragraph.attributedString))
                return true
            }
            return found
        }

        private func pictureWidths(_ text: NSAttributedString) -> [CGFloat] {
            var widths: [CGFloat] = []
            text.enumerateAttribute(.picture, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let picture = value as? ShownImage { widths.append(picture.size.width) }
            }
            return widths
        }

        /// What differs between the paragraphs in `w`'s window and those of a window of the same
        /// size that has only just loaded the same text; nil when nothing does.
        private func difference(_ w: EditorWindow, documentURL: URL? = nil) -> String? {
            let fresh = EditorWindow(w.textView.string, size: w.window.contentRect(forFrameRect: w.window.frame).size, documentURL: documentURL)
            defer { fresh.close() }
            fresh.textView.setSelectedRange(w.textView.selectedRange())
            fresh.pump(0.01)
            let paragraphs = shown(w)
            guard paragraphs.count > 3 else { return "only \(paragraphs.count) paragraphs are laid out for the window" }
            for (offset, text) in paragraphs where text.length > 0 {
                let expected = fresh.displayParagraph(at: offset).text
                let pictures = pictureWidths(text)
                // A picture's value does not compare; its size and the text around it do.
                let isSame = pictures.isEmpty ? text.isEqual(to: expected) : text.string == expected.string && pictures == pictureWidths(expected)
                if !isSame { return "the paragraph at \(offset), \(text.string.debugDescription)" }
            }
            return nil
        }

        /// One frame's worth: the scroll and the layout that follows it, without a turn of the run loop.
        private func scroll(_ w: EditorWindow, toEnd: Bool) {
            let clip = w.editor.scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: toEnd ? max(0, w.textView.frame.height - clip.bounds.height) : 0))
            w.editor.scrollView.reflectScrolledClipView(clip)
            w.window.layoutIfNeeded()
        }

        private func visit(_ w: EditorWindow) {
            for toEnd in [true, false] {
                scroll(w, toEnd: toEnd)
                w.pump()
            }
        }

        @Test func rowsThatWereOffScreenWhenAColumnMovedShowTheNewColumnsInTheFrameThatBringsThemIn() throws {
            let rows = (1...300).map { "| \($0) | item \($0) of the store room | `c\($0)` |\n" }.joined()
            let w = EditorWindow("intro\n\n| No | Item | Code |\n|---:|:---|:---:|\n" + rows + "\nend\n")
            defer { w.close() }
            // TextKit has the last rows: they were on screen once.
            visit(w)
            var last: Int { w.offset(of: "| 300 |") }
            let before = try #require((w.layout.textLayoutFragment(for: w.content.location(w.content.documentRange.location, offsetBy: last)!)?
                .textElement as? NSTextParagraph)?.attributedString.attribute(.tableRow, at: 0, effectiveRange: nil) as? TableRow)

            w.select(w.offset(of: "item 2 of") + 6)
            w.type(" and a much longer name")
            #expect(difference(w) == nil, "the rows in the window follow the column at once")
            let top = try #require(w.displayAttributes(at: w.offset(of: "| 2 |"))[.tableRow] as? TableRow)
            #expect(top.edges != before.edges, "the column did move")

            scroll(w, toEnd: true)
            #expect(difference(w) == nil, "rows laid out before the column moved are asked for again as they come in")
            // Heights are estimates until they are laid out: the end is reached in a second step.
            w.pump()
            scroll(w, toEnd: true)
            #expect(shown(w).contains { $0.offset == last }, "the last rows are in the window")
            #expect(difference(w) == nil)

            // Undo is no edit that is asked about: the whole table is restyled, and the window is taken to the edit.
            w.undoAll()
            #expect(difference(w) == nil)
            scroll(w, toEnd: true)
            #expect(difference(w) == nil)
            w.pump()
            scroll(w, toEnd: true)
            #expect(difference(w) == nil, "and back at the end the columns are the old ones")
            let after = try #require(shown(w).first { $0.offset == last }?.text.attribute(.tableRow, at: 0, effectiveRange: nil) as? TableRow)
            #expect(after.edges == before.edges)

            // Too narrow for single lines: the cells of every row wrap, wherever the window is when it turns.
            w.window.setContentSize(NSSize(width: 320, height: 600))
            w.pump()
            #expect(difference(w) == nil, "\(difference(w) ?? "")")
            #expect((w.displayAttributes(at: last)[.tableRow] as? TableRow)?.cellStarts.count == 3)
            scroll(w, toEnd: false)
            #expect(difference(w) == nil)
            w.window.setContentSize(NSSize(width: 900, height: 600))
            w.pump()
            #expect(difference(w) == nil && (w.displayAttributes(at: last)[.tableRow] as? TableRow)?.cellStarts == [])
            scroll(w, toEnd: true)
            #expect(difference(w) == nil)
            #expect(w.storageProblem == nil)
        }

        /// Rows that are asked for again as they come into the window lose the layout they had
        /// just been given. They are laid out again before the frame is drawn, not drawn as they were.
        @Test func rowsThatComeInBehindANudgeAreDrawnFromTheirNewLayoutInThatFrame() {
            let rows = (1...300).map { "| \($0) | item \($0) of the store room | `c\($0)` |\n" }.joined()
            let w = EditorWindow("intro\n\n| No | Item | Code |\n|---:|:---|:---:|\n" + rows + "\nend\n")
            defer { w.close() }
            visit(w)
            w.select(w.offset(of: "item 2 of") + 6)
            w.type(" and a much longer name")
            w.pump()
            #expect(w.paintProblem == nil, "\(w.paintProblem ?? "")")
            scroll(w, toEnd: true)
            #expect(w.paintProblem == nil, "\(w.paintProblem ?? "")")
            #expect(difference(w) == nil)
        }

        /// The same in a long text whose table is too wide for single lines: the cells of every
        /// row wrap in columns that all rows share, also the rows far from the window.
        @Test func rowsOfWrappingCellsThatWereOffScreenWhenTheColumnsMovedShowTheNewColumnsWhenTheyComeIn() throws {
            let filler = (1...30).map { "Paragraph \($0) of the text around the table, long enough to take a line or two of the column.\n\n" }.joined()
            let words = "words that fill the cell and wrap in its column, as the text of a real table does"
            let rows = (1...80).map { "| row \($0) | \(words), \(words) \($0) | note \($0)<br>second line |\n" }.joined()
            let w = EditorWindow(filler + "| Name | What it holds | Note |\n|---|---|---|\n" + rows + "\n" + filler + "end\n")
            defer { w.close() }
            visit(w)
            func grid(_ offset: Int) -> TableRow? {
                (w.layout.textLayoutFragment(for: w.content.location(w.content.documentRange.location, offsetBy: offset)!)?
                    .textElement as? NSTextParagraph)?.attributedString.attribute(.tableRow, at: 0, effectiveRange: nil) as? TableRow
            }
            var last: Int { w.offset(of: "| row 80 |") }
            // The table has not been in the window yet; its last rows are among what TextKit lays out at the end of a text.
            w.select(w.offset(of: "row 2 |") + 5)
            w.editor.scrollToSelection()
            w.pump()
            let before = try #require(grid(w.offset(of: "| row 3 |")))
            #expect(before.cellStarts.count == 3 && difference(w) == nil)

            w.type(" with a longer name")
            #expect(difference(w) == nil, "the rows in the window follow the columns at once")
            let moved = try #require(grid(w.offset(of: "| row 3 |")))
            #expect(moved.edges != before.edges && moved.cellStarts.count == 3, "the first column did get wider")

            scroll(w, toEnd: true)
            #expect(difference(w) == nil)
            w.pump()
            // The table's last rows, in the frame that brings them in.
            w.select(last + 4)
            w.editor.scrollToSelection()
            #expect(shown(w).contains { $0.offset == last }, "the last rows are in the window: \(shown(w).map(\.offset)) for \(last), caret \(w.caretRect(at: last + 4)) in \(w.textView.visibleRect)")
            #expect(difference(w) == nil, "rows laid out before the columns moved are asked for again as they come in")
            #expect(grid(last)?.edges == moved.edges)
            for (offset, _) in shown(w) {
                let fragment = w.layout.textLayoutFragment(for: w.content.location(w.content.documentRange.location, offsetBy: offset)!)
                #expect((fragment as? BlockFragment)?.fitsItsCells == true, "a row at \(offset) is not as high as its cells")
            }

            w.undoAll()
            #expect(difference(w) == nil)
            w.select(last + 4)
            w.editor.scrollToSelection()
            #expect(difference(w) == nil && grid(last)?.edges == before.edges, "and after undo the columns are the old ones there too")
            #expect(w.storageProblem == nil)
        }

        /// A resize: text wraps anew without being asked for again, pictures are scaled to the
        /// column and a table's cells wrap, in the window at once and elsewhere when the window
        /// gets there.
        @Test func afterAResizeEverythingShowsAsInAFreshWindowOnceItIsInView() throws {
            let document = Fixtures.url("images.md")
            let filler = (1...60).map { "Paragraph \($0) with enough words in it to need a second line once the window is narrow.\n\n" }.joined()
            let table = "| Name | Quantity | A note that takes room |\n|:--|--:|:-:|\n| apple | 3 | plain and simple |\n| kiwi | 12 | **green** |\n\n"
            let w = EditorWindow("A first paragraph that is long enough to wrap when the window is narrow, and not before.\n\n![a](images/pic.png)\n\n"
                + filler + table + "![b](images/pic.png)\n\nend\n", size: NSSize(width: 800, height: 600), documentURL: document)
            defer { w.close() }
            visit(w)
            let first = w.layout.textLayoutFragment(for: w.content.documentRange.location)
            let lines = try #require(first?.textLineFragments.count), paragraph = first?.textElement
            #expect(difference(w, documentURL: document) == nil)

            w.window.setContentSize(NSSize(width: 330, height: 600))
            w.pump()
            let narrow = w.layout.textLayoutFragment(for: w.content.documentRange.location)
            #expect(try #require(narrow?.textLineFragments.count) > lines, "the text wraps anew")
            #expect(narrow?.textElement === paragraph, "without being asked for again")
            let column = w.textView.columnWidth
            #expect(shown(w).flatMap { pictureWidths($0.text) } == [column], "the picture in the window is as wide as the column")
            #expect(difference(w, documentURL: document) == nil)

            scroll(w, toEnd: true)
            #expect(difference(w, documentURL: document) == nil, "what was laid out at the old width is asked for again as it comes in")
            #expect(shown(w).flatMap { pictureWidths($0.text) } == [column])
            #expect((w.displayAttributes(at: w.offset(of: "| apple"))[.tableRow] as? TableRow)?.cellStarts.count == 3, "the table does not fit on single lines: its cells wrap")

            // Wider than the column: the container runs on beside it for the table, and everything is restyled.
            w.window.setContentSize(NSSize(width: 1000, height: 600))
            w.pump()
            #expect(difference(w, documentURL: document) == nil)
            #expect((w.displayAttributes(at: w.offset(of: "| apple"))[.tableRow] as? TableRow)?.cellStarts == [])
            scroll(w, toEnd: false)
            #expect(difference(w, documentURL: document) == nil)
            #expect(shown(w).flatMap { pictureWidths($0.text) } == [640])
        }

        /// A selection of everything reveals every marker; only the window's paragraphs are made again for it.
        @Test func aChangeOfTheWholeTextIsShownWhereverTheWindowGoesNext() {
            let w = EditorWindow((1...400).map { "Line \($0) with **bold** and `code` in it.\n\n" }.joined())
            defer { w.close() }
            visit(w)
            w.textView.selectAll(nil)
            w.pump()
            #expect(difference(w) == nil)
            scroll(w, toEnd: true)
            #expect(difference(w) == nil)
            w.select(0)
            w.pump()
            scroll(w, toEnd: true)
            #expect(difference(w) == nil && w.storageProblem == nil)
        }
    }
}
