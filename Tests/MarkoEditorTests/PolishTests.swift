import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    /// Regressions across all areas, each as it shows in a real window.
    @Suite struct PolishTests {
        private let theme = Theme.standard
        /// A reference to a link defined elsewhere can only be read with the whole text, for which a text of this size waits.
        private let large = String(repeating: "some words in a line of text\n\n", count: 4000) + "[ref]: /url\n"

        private func color(_ w: EditorWindow, at offset: Int) -> NSColor? {
            w.displayAttributes(at: offset)[.foregroundColor] as? NSColor
        }

        // MARK: tables

        @Test func rowsAppendedWithTabDoNotWidenTheColumns() {
            let w = EditorWindow("")
            defer { w.close() }
            w.type("| a | b |\r")
            var edges: Set<[CGFloat]> = []
            for _ in 0..<6 {
                w.type("x\ty\t")
                edges.insert((w.displayAttributes(at: 0)[.tableRow] as? TableRow)?.edges ?? [])
            }
            #expect(w.textView.string == "| a | b |\n| --- | --- |\n" + String(repeating: "| x | y |\n", count: 6) + "|  |  |")
            #expect(edges.count == 1 && edges.first?.count == 3, "the grid is as wide after every row")
        }

        @Test func anEscapedPipeIsTypedAndDeletedAsOne() {
            let tight = "|x|a|\n|-|-|\n|c|d|\n"
            let w = EditorWindow(tight)
            defer { w.close() }
            w.select(w.offset(of: "a|") + 1)
            w.type("|")
            #expect(w.textView.string == "|x|a\\||\n|-|-|\n|c|d|\n")
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string == tight, "Backspace takes back what the key put in")

            for (caret, key) in [(1, #selector(NSResponder.deleteBackward(_:))), (0, #selector(NSResponder.deleteForward(_:))),
                                 (1, #selector(NSResponder.deleteForward(_:))), (2, #selector(NSResponder.deleteBackward(_:)))] {
                w.editor.text = "| x | a\\|b |\n|---|---|\n| c | d |"
                w.select(w.offset(of: "\\|") + caret)
                w.command(key)
                #expect(w.textView.string == "| x | ab |\n|---|---|\n| c | d |", "caret \(caret) from the backslash, \(key)")
                #expect(MarkdownStyler.style(w.textView.string).tables.count == 1)
            }
        }

        @Test func aSelectionNeverEndsInsideADelimiterRowThatEndsTheText() {
            let w = EditorWindow("| a | b |\n|---|---|")
            defer { w.close() }
            w.select(0)
            w.command(#selector(NSResponder.selectParagraph(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 0, length: 19), "the hidden row is taken whole")
            for end in 10...19 {
                w.select(2)
                w.select(2, length: end - 2)
                #expect(w.textView.selectedRange() == NSRange(location: 2, length: 17), "a selection end at \(end)")
                w.select(end)
                #expect(w.textView.selectedRange() == NSRange(location: 8, length: 0), "a caret at \(end) goes back into the header")
            }
            w.select(0, length: 11)
            w.command(#selector(NSResponder.deleteBackward(_:)))
            #expect(w.textView.string == "", "no part of the row is left behind")
        }

        @Test func figuresInAColumnLineUp() {
            let w = EditorWindow("| n |\n|--:|\n| 13.1 |\n| 10.0 |\n| 77.7 |\n\nend")
            defer { w.close() }
            w.select(w.length)
            let starts = ["13.1", "10.0", "77.7"].map { w.columnX(at: w.offset(of: $0)) }
            #expect(starts.allSatisfy { abs($0 - starts[0]) < 0.01 }, "\(starts)")
        }

        // MARK: format commands

        @Test func aMarkerTypedOverALineSelectedWithItsBreakStaysOnTheLine() {
            let w = EditorWindow("word here\nnext\n")
            defer { w.close() }
            w.select(0, length: 10)
            w.type("*")
            #expect(w.textView.string == "*word here*\nnext\n")
            #expect(w.displayFont(at: 3).fontDescriptor.symbolicTraits.contains(.italic))
        }

        @Test func aListStartedOnTheLineBelowAParagraphIsAListAndTogglesOff() {
            for (title, marker) in [("Bullet List", "- "), ("Ordered List", "1. ")] {
                let w = EditorWindow("a\n")
                defer { w.close() }
                w.select(2)
                #expect(w.chooseFormat(title).isEnabled)
                #expect(w.textView.string == "a\n\n\(marker)")
                #expect(MarkdownStyler.style(w.textView.string).lines.map(\.kind) == [.paragraph, .blank, .blank])
                let again = w.chooseFormat(title)
                #expect(again.isEnabled && again.isOn && w.textView.string == "a\n\n")
            }
        }

        // MARK: images

        @Test func aPastedFileWithAHashOrAPercentInItsNameShows() throws {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("marko-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let w = EditorWindow("", documentURL: folder.appendingPathComponent("doc.md"))
            defer { w.close() }
            for (name, markup) in [("shot #1.png", "![shot #1](shot%20%231.png)"), ("a%20b.png", "![a%20b](a%2520b.png)")] {
                let file = folder.appendingPathComponent(name)
                try Fixtures.data("images/pic.png").write(to: file)
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                pasteboard.clearContents()
                pasteboard.writeObjects([file as NSURL])
                w.editor.text = ""
                #expect(w.textView.readSelection(from: pasteboard, type: .fileURL))
                w.pump()
                #expect(w.textView.string == markup)
                let shown = w.displayAttributes(at: 0)[.picture] as? ShownImage
                #expect(shown?.image != nil && shown?.isMissing == false, "\(name)")
            }
        }

        @Test func onlyRegularFilesAreReadAndUnusedImagesAreLetGo() throws {
            let cache = ImageCache()
            guard case .missing = cache.entry(for: "/dev/zero") else {
                Issue.record("a device is not an image")
                return
            }
            guard case .image = cache.entry(for: Fixtures.url("images/pic.png").absoluteURL.path) else {
                Issue.record("a file is")
                return
            }
            WebStub.install()
            cache.allowsRemote = true
            guard case .loading = cache.entry(for: "https://images.marko.test/partial") else {
                Issue.record("a web image loads")
                return
            }
            cache.keep(["/dev/zero"])
            #expect(!cache.isEmpty)
            cache.keep([])
            #expect(cache.isEmpty, "what no line shows any more is dropped")
        }

        @Test func anImageOverPlainHTTPIsFetchedOverHTTPS() async throws {
            WebStub.responses[URL(string: "https://images.marko.test/plain.png")!] = try Fixtures.data("images/pic.png")
            let w = EditorWindow("![x](http://images.marko.test/plain.png)\n")
            defer { w.close() }
            w.editor.loadsRemoteImages = true
            func shown() -> ShownImage? { w.displayAttributes(at: 0)[.picture] as? ShownImage }
            for _ in 0..<100 where shown()?.image == nil { try await Task.sleep(for: .milliseconds(20)) }
            #expect(shown()?.image != nil)
        }

        // MARK: page and rhythm

        @Test func theTextEndsWellAboveTheWindowsEdgeAndTypingKeepsRoomBelowTheCaret() {
            let w = EditorWindow(String(repeating: "line\n", count: 200) + "last")
            defer { w.close() }
            let origin = w.textView.textContainerOrigin
            #expect(origin.y == theme.pagePadding.height)
            #expect(abs(w.textView.frame.height - origin.y - w.fragment(at: w.length - 1).layoutFragmentFrame.maxY - theme.pageBottomPadding) < 1)
            w.select(w.length)
            w.type(" x")
            let caret = w.characterRect(at: w.length - 1)
            #expect(caret.maxY <= w.textView.visibleRect.maxY - theme.scrollMargin + 1, "the line being written is clear of the edge")
            #expect(w.storageProblem == nil)
        }

        @Test func anEditAwayFromTheCaretDoesNotScrollToIt() {
            let w = EditorWindow("- [ ] task\n" + String(repeating: "line\n", count: 200))
            defer { w.close() }
            w.select(w.length)
            w.textView.scroll(.zero)
            w.pump()
            let visible = w.textView.visibleRect, box = w.characterRect(at: 2)
            w.mouseDown(at: NSPoint(x: box.midX, y: box.midY))
            #expect(w.textView.string.hasPrefix("- [x] task") && w.textView.visibleRect == visible)
        }

        @Test func aHeadingHasMoreRoomAboveThanBelow() {
            let w = EditorWindow("# One\n\ntext\n\n## Two\n\ntext\n\n### Three\n\ntext\n")
            defer { w.close() }
            w.select(w.length)
            func room(_ heading: String) -> (above: CGFloat, below: CGFloat) {
                let fragment = w.fragment(at: w.offset(of: heading)), line = fragment.textLineFragments[0].typographicBounds
                return (line.minY, fragment.layoutFragmentFrame.height - line.maxY)
            }
            #expect(room("# One").above == 0, "the first line has the page's padding")
            #expect(room("## Two").above == theme.headingSpacingsBefore[1] && room("## Two").below == theme.underlineLineHeight)
            #expect(room("### Three").above == theme.headingSpacingsBefore[2] && room("### Three").below == theme.headingSpacingAfter)
            for heading in ["## Two", "### Three"] { #expect(room(heading).above > room(heading).below + 2) }
        }

        @Test func theItemsOfAListStartInOneColumnWhateverTheirNumbers() {
            for source in ["8. eight\n9. nine\n10. ten\n11. eleven\n", "1. one\n2. two\n\n10. ten\n100. hundred\n"] {
                let w = EditorWindow(source)
                defer { w.close() }
                w.select(w.length)
                let map = MarkdownStyler.style(source)
                let starts = map.lines.filter { !$0.listMarkers.isEmpty }.map { w.columnX(at: NSMaxRange($0.prefixRange)) }
                #expect(starts.count == 4 && starts.allSatisfy { abs($0 - starts[0]) < 0.5 }, "\(starts)")
            }
        }

        // MARK: source that is not rendered

        @Test func sourceLinesAreSetSmallAndMutedAndInlineHTMLIsDim() throws {
            let source = "---\ntitle: x\n---\n\n<div align=\"center\">\n</div>\n\nPress <kbd>Cmd</kbd> now.\n\n[ref]: https://example.com\n"
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(w.offset(of: "Press"))
            for text in ["title: x", "<div", "</div>", "[ref]:"] {
                let offset = w.offset(of: text)
                #expect(w.displayFont(at: offset) == theme.codeFont(size: theme.codeBlockFontSize) && color(w, at: offset) == theme.mutedText, "\(text)")
                #expect(w.fragment(at: offset).textLineFragments[0].typographicBounds.height == theme.codeBlockLineHeight)
            }
            #expect(color(w, at: w.offset(of: "<kbd>")) == theme.marker && color(w, at: w.offset(of: "</kbd>") + 2) == theme.marker)
            #expect(color(w, at: w.offset(of: "Cmd")) == theme.text && w.displayFont(at: w.offset(of: "<kbd>")) == theme.bodyFont)
            #expect(w.textView.string == source && w.storageProblem == nil)
        }

        @Test func anEscapingBackslashIsHiddenUntilTheCaretTouchesIt() {
            let w = EditorWindow("\\*not emphasis\\* here\n\n| a | b |\n|---|---|\n| c \\| d | e |\n\nend")
            defer { w.close() }
            w.select(w.length)
            #expect(w.isHidden(0) && !w.isHidden(1) && w.isHidden(w.offset(of: "\\* here")))
            let plain = NSAttributedString(string: "*not emphasis* here", attributes: [.font: theme.bodyFont])
            #expect(abs(w.lineWidth(at: 0) - referenceWidth(plain)) < 0.1)
            let cell = w.offset(of: "\\| d")
            #expect(w.isHidden(cell) && !w.isHidden(cell + 1))
            for caret in 0...2 {
                w.select(caret)
                #expect(!w.isHidden(0) && color(w, at: 0) == theme.marker && w.isHidden(w.offset(of: "\\* here")), "caret at \(caret)")
            }
            w.select(3)
            #expect(w.isHidden(0))
            w.select(0)
            for expected in 1...5 {
                w.command(#selector(NSResponder.moveRight(_:)))
                #expect(w.textView.selectedRange() == NSRange(location: expected, length: 0))
            }
            #expect(w.storageProblem == nil)
        }

        // MARK: large documents

        @Test func anAnchorLinkFollowedStraightAfterTypingFindsItsHeading() {
            let w = EditorWindow("# [ref]\n\n" + large + "# The End\n\ntext\n")
            defer { w.close() }
            w.select(3)
            w.type("xx")
            w.editor.open("#the-end")
            #expect(w.textView.selectedRange() == NSRange(location: w.offset(of: "The End"), length: 0))
        }

        @Test func validatingTheMenusDoesNotParseALargeDocument() {
            let w = EditorWindow("- item [ref]\n\n" + large)
            defer { w.close() }
            w.select(6)
            w.type(" more")
            for title in ["Bold", "Bullet List", "Insert Row Below"] {
                #expect(w.chooseFormat(title, perform: false).isEnabled, "offered until it is chosen")
            }
            #expect(w.displayAttributes(at: 0)[.glyphLift] == nil, "no parse for the menu: the line still shows raw")
            w.chooseFormat("Bullet List")
            #expect(w.textView.string.hasPrefix("item more [ref]\n"), "the command itself parses first: a map that is behind gives no edit")
        }

        @Test func aHeadingsRuleFollowsTheColumnWhenTheWindowNarrowsWithoutRewrappingIt() throws {
            let w = EditorWindow("# On Writing Tools That Disappear\n\nText.\n\n```\ncode\n```\n", size: NSSize(width: 480, height: 400))
            defer { w.close() }
            // The caret is on the heading, which shows its marker and wraps onto a second line.
            w.select(0)
            let before = try #require(w.fragment(at: 0) as? BlockFragment), column = w.textView.columnWidth
            #expect(before.textLineFragments.count == 2 && before.hairlineRect?.maxX == column)
            let code = w.fragment(at: w.offset(of: "code")).textElement

            // A few points narrower, as in every step of the sidebar sliding in: the lines stay as
            // they are, and so do the bounds the heading draws in. Everything on screen is drawn
            // again all the same, without being asked for again.
            func paragraphViews() -> [NSView] { w.textView.subviews.flatMap(\.subviews) }
            w.window.displayIfNeeded()
            let views = Set(paragraphViews().map(ObjectIdentifier.init))
            CATransaction.flush()
            func isToBeDrawn(_ view: NSView) -> Bool { view.needsDisplay || view.layer?.needsDisplay() == true }
            #expect(!views.isEmpty && !paragraphViews().contains(where: isToBeDrawn))
            w.window.setContentSize(NSSize(width: 470, height: 400))
            w.window.layoutIfNeeded()
            let states = paragraphViews().map { "\(views.contains(ObjectIdentifier($0)) ? "old" : "new") \($0.needsDisplay) \($0.layer?.needsDisplay() ?? false)" }
            #expect(paragraphViews().allSatisfy { isToBeDrawn($0) || !views.contains(ObjectIdentifier($0)) }, "a paragraph's view is new or is drawn again: \(states)")
            w.pump()
            let after = try #require(w.fragment(at: 0) as? BlockFragment)
            #expect(w.textView.columnWidth == column - 10 && after.textLineFragments.count == 2)
            #expect(after.textElement === before.textElement, "what a paragraph is made of does not depend on the width")
            #expect(after.hairlineRect?.maxX == column - 10)
            // So is code, whose panel is as wide as the column.
            #expect(w.fragment(at: w.offset(of: "code")).textElement === code)
            let panel = try #require((w.fragment(at: w.offset(of: "code")) as? BlockFragment)?.codePanelRect)
            #expect(w.inColumn(panel, ofFragmentAt: w.offset(of: "code")).maxX == column - 10)
        }

        // MARK: input methods and undo

        @Test func aCompositionThatIsGivenUpLeavesTheLinesAsTheyWere() {
            // TextKit lays out the first and the last lines of a text for its estimates, not the middle.
            let lines = String(repeating: "a line of text\n\n", count: 300)
            let source = "**b** tail\n\n" + lines + "far below\n\n" + lines
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(11)
            w.pump(0.01)

            // An opening fence is composed on the empty line: everything below it is code meanwhile,
            // and what is laid out for the first time now shows as that.
            w.textView.setMarkedText("```", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 11, length: 0))
            w.pump(0.01)
            #expect(w.textView.hasMarkedText() && w.displayAttributes(at: w.offset(of: "far below"))[.codePanel] != nil)
            // Given up, as Escape does in an input method: no text is left and nothing tells of a change.
            w.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            w.textView.unmarkText()
            w.pump(0.01)
            #expect(!w.textView.hasMarkedText() && w.textView.string == source)
            let far = w.offset(of: "far below")
            #expect(w.displayAttributes(at: far)[.codePanel] == nil && w.displayFont(at: far) == theme.bodyFont,
                    "the lines the composition made code are text again")
            #expect(w.textView.selectedRange() == NSRange(location: 11, length: 0) && w.isHidden(0))
            w.select(3)
            #expect(!w.isHidden(0))
            #expect(w.storageProblem == nil)
        }

        @Test func textThatUndoPutsBackAfterAZoomHasTheNewSize() {
            let w = EditorWindow("one\n\ntwo words\n\nthree\n")
            defer {
                Theme.zoom = 1
                w.close()
            }
            let two = w.offset(of: "two")
            w.select(two, length: 11)
            w.type(String(EditorWindow.backspace))
            #expect(w.textView.string == "one\n\nthree\n")
            Theme.zoom = 1.5
            w.pump()
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "one\n\ntwo words\n\nthree\n")
            #expect(w.storageProblem == nil, "the storage holds nothing of the old size")
            #expect(w.displayFont(at: two).pointSize == 24 && w.fragment(at: two).layoutFragmentFrame.height == 39)
            w.textView.undoManager?.redo()
            w.textView.undoManager?.undo()
            Theme.zoom = 1
            w.pump()
            #expect(w.storageProblem == nil && w.fragment(at: two).layoutFragmentFrame.height == 26)
        }

        @Test func aZoomKeepsTheParagraphAtTheTopOfTheViewThere() {
            let source = (1...300).map { "Paragraph number \($0) with enough words in it to fill more than one line of the page.\n\n" }.joined()
            let w = EditorWindow(source, size: NSSize(width: 500, height: 600))
            defer {
                Theme.zoom = 1
                w.close()
            }
            w.select(w.offset(of: "number 150 "))
            w.editor.scrollToSelection()
            w.pump()
            let top = w.editor.place.top
            #expect(top != nil && (top?.offset ?? 0) > 5000)
            for zoom: CGFloat in [2, 1, 0.8, 2, 1] {
                Theme.zoom = zoom
                w.pump()
                #expect(w.editor.place.top?.offset == top?.offset, "zoom \(zoom)")
            }
            // Scrolled to the end, where the view was when the layout once never returned after a zoom.
            w.command(#selector(NSResponder.moveToEndOfDocument(_:)))
            w.pump()
            let last = w.editor.place.top
            #expect((last?.offset ?? 0) > (top?.offset ?? 0))
            for zoom: CGFloat in [2, 1, 2, 1] {
                Theme.zoom = zoom
                w.pump()
            }
            #expect(w.editor.place.top?.offset == last?.offset && w.textView.selectedRange().location == w.length && w.storageProblem == nil)
        }

        @Test func selectingAllOfALongDocumentRevealsAndHidesEveryMarker() {
            let source = String(repeating: "a **bold** word and `code`\n", count: 300)
            let w = EditorWindow(source)
            defer { w.close() }
            let later = w.offset(of: "**bold**") + 27 * 250
            w.select(w.length)
            #expect(w.isHidden(2) && w.isHidden(later))
            w.select(0, length: w.length)
            #expect(!w.isHidden(2) && !w.isHidden(later))
            w.select(w.length)
            #expect(w.isHidden(2) && w.isHidden(later))
            #expect(w.textView.string == source && w.storageProblem == nil)
        }

        // MARK: the layout that never returned

        /// Found by a seeded random run (window 1300 x 800, zoom 2, a text of 290 units scrolled
        /// down): undoing a line typed near the end left only the text's end laid out, and the
        /// view's next layout never came back from `-[NSTextLayoutManager ensureLayoutForBounds:]`,
        /// with memory growing. A layout that does not return would hang the whole run, so this
        /// ends the process with a message instead.
        @Test func undoingALineNearTheEndOfAScrolledTextAtZoomTwoStillLaysOut() {
            let hang = DispatchWorkItem { fatalError("the text view's layout did not return within 30 seconds") }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: hang)
            defer { hang.cancel() }
            defer { Theme.zoom = 1 }
            let text = "# A [ful[x](y) l reference][ref-`d ax\tn image ![alt teword x`t][logo]`.\n\nAn <http# s:[x](y)//example.com/autolink> "
                + "and a bare https://example.com/bare link.\n\n\n[ref-o//exwide wide wide wideample.com/one-  \"Title Onrd s://example.com/two>\n"
                + "e.com/three\n   'Title on n# ext li\n---\nne'\n[logo]: ./"
            let w = EditorWindow(text, size: NSSize(width: 1300, height: 800))
            defer { w.close() }
            Theme.zoom = 2
            w.pump()
            w.command(#selector(NSResponder.moveToEndOfDocument(_:)))
            w.pump(0.01)
            w.textView.insertText("| p | q |\n", replacementRange: NSRange(location: 279, length: 0))
            w.pump(0.01)
            w.select(224, length: 76)
            w.pump(0.01)
            w.editor.scrollToSelection()
            w.pump(0.01)
            #expect(w.editor.scrollView.contentView.bounds.minY > 100, "scrolled down, with the start of the text out of sight")
            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == text && w.storageProblem == nil)
            // The text is where the window shows it: a paragraph at the top of the visible part.
            let top = CGPoint(x: 1, y: w.textView.visibleRect.minY - w.textView.textContainerOrigin.y + 1)
            #expect(w.layout.textLayoutFragment(for: top)?.state == .layoutAvailable)
        }
    }
}
