import AppKit
import FixtureSupport
import MarkoCore
import Testing
@testable import MarkoEditor

extension EditorTests {
    @Suite struct RenderingTests {
        private let theme = Theme.standard
        private let sample = "# Heading one\na **bold** word and `code` here\nsee [link](http://x.y) end\nplain line\n"

        // MARK: inline rendering

        @Test func hiddenLineWidthEqualsTheMarkerFreeReference() {
            let w = EditorWindow(sample)
            defer { w.close() }
            w.select(w.length)
            w.pump()
            for offset in [0, 14, 46] {
                let (text, _) = w.displayParagraph(at: offset)
                let reference = NSMutableAttributedString(attributedString: text)
                var hidden = 0
                for index in (0..<reference.length).reversed() {
                    let font = reference.attribute(.font, at: index, effectiveRange: nil) as! NSFont
                    let isNewline = (reference.string as NSString).character(at: index) == 0x0A
                    if font.pointSize < 1 { hidden += 1 }
                    if font.pointSize < 1 || isNewline { reference.deleteCharacters(in: NSRange(location: index, length: 1)) }
                }
                #expect(hidden > 0, "line at \(offset) has hidden markers")
                #expect(abs(w.lineWidth(at: offset) - referenceWidth(reference)) < 0.1, "line at \(offset)")
            }

            let collapsed = w.lineWidth(at: 14)
            w.select(20)
            w.pump()
            let stars = referenceWidth(NSAttributedString(string: "****", attributes: [.font: theme.bodyFont]))
            #expect(abs(w.lineWidth(at: 14) - collapsed - stars) < 0.1, "revealing shows the four asterisks at full size")
            w.select(w.length)
            w.pump()
            #expect(abs(w.lineWidth(at: 14) - collapsed) < 0.01, "and collapsing hides them again")
        }

        @Test func moveRightAndMoveLeftAdvanceOneOffsetPerPress() {
            let w = EditorWindow(sample)
            defer { w.close() }
            w.select(0)
            for expected in 1...w.length {
                w.textView.moveRight(nil)
                #expect(w.textView.selectedRange() == NSRange(location: expected, length: 0))
            }
            for expected in (0..<w.length).reversed() {
                w.textView.moveLeft(nil)
                #expect(w.textView.selectedRange() == NSRange(location: expected, length: 0))
            }
            w.select(14)
            for length in 1...30 {
                w.textView.moveRightAndModifySelection(nil)
                #expect(w.textView.selectedRange() == NSRange(location: 14, length: length))
            }
        }

        @Test func undoRestoresTheExactStringAndStorageStaysPlain() {
            let w = EditorWindow(sample)
            defer { w.close() }
            w.select(w.length - 1)
            w.type(" **hi** z")
            #expect(w.textView.string == String(sample.dropLast()) + " **hi** z\n")
            w.select(20)
            w.type("XY")
            #expect(w.textView.string.contains("a **boXYld** word"))
            #expect(w.storageProblem == nil)

            w.undoAll()
            #expect(w.textView.string == sample)
            #expect(w.storageProblem == nil)
            w.textView.undoManager?.redo()
            w.pump()
            #expect(w.textView.string.hasSuffix("plain line **hi** z\n"))
            #expect(w.storageProblem == nil)
            #expect(w.textView.textLayoutManager != nil)
        }

        @Test func typingAHeadingAndBoldConvertsLive() {
            let w = EditorWindow()
            defer { w.close() }
            w.type("# Title")
            #expect(w.displayFont(at: 3) == theme.headingFont(level: 1))
            #expect(!w.isHidden(0), "the caret is on the heading line, so its marker shows")
            #expect(w.displayAttributes(at: 0)[.foregroundColor] as? NSColor == theme.marker)

            w.type("\r**x**")
            #expect(w.textView.string == "# Title\n**x**")
            #expect(w.isHidden(0) && w.isHidden(1), "the caret left the heading line")
            #expect(w.displayFont(at: 3) == theme.headingFont(level: 1))
            #expect(w.displayFont(at: 10).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.displayFont(at: 10).pointSize == theme.bodySize)
            #expect(!w.isHidden(8) && !w.isHidden(12), "the caret touches the token's end")
            #expect(w.displayAttributes(at: 8)[.foregroundColor] as? NSColor == theme.marker)

            w.type(" y")
            #expect([8, 9, 11, 12].allSatisfy(w.isHidden))
            #expect(!w.displayFont(at: 14).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.textView.string == "# Title\n**x** y")
            #expect(w.storageProblem == nil)
        }

        // MARK: inline tokens

        @Test func inlineTokensGetTheirStyles() {
            let source = "*em* ~~gone~~ `code` [text](http://u) <http://auto> ![alt](pic.png) ***both***\n\nend\n"
            let w = EditorWindow(source)
            defer { w.close() }
            w.select(w.length)
            w.pump()
            func offset(_ text: String) -> Int { (source as NSString).range(of: text).location }

            #expect(w.displayFont(at: offset("em")).fontDescriptor.symbolicTraits.contains(.italic))
            #expect(w.displayAttributes(at: offset("gone"))[.strikethroughStyle] != nil)
            #expect(w.displayFont(at: offset("code")).fontDescriptor.symbolicTraits.contains(.monoSpace))
            #expect(w.displayAttributes(at: offset("code"))[.inlineBackground] as? NSColor == theme.codeBackground)
            // The hidden backticks are the room between the background's edge and the code.
            let tick = offset("`code"), comma = offset("code`") + 5
            #expect(w.displayAttributes(at: tick)[.foregroundColor] as? NSColor == .clear)
            #expect(w.displayAttributes(at: tick)[.inlineBackground] != nil && w.displayAttributes(at: comma)[.inlineBackground] == nil)
            #expect(abs(w.characterRect(at: tick).width - theme.inlineCodePadding.width) < 0.25)
            #expect(abs(w.characterRect(at: comma - 1).width - theme.inlineCodePadding.width) < 0.25)
            #expect(w.displayAttributes(at: offset("text"))[.foregroundColor] as? NSColor == theme.link)
            #expect(w.displayAttributes(at: offset("text"))[.underlineStyle] == nil)
            #expect(w.isHidden(offset("](http://u)")) && w.isHidden(offset("http://u")))
            #expect(w.displayAttributes(at: offset("http://auto"))[.foregroundColor] as? NSColor == theme.link)
            #expect(w.isHidden(offset("<http://auto")))
            let both = w.displayFont(at: offset("both")).fontDescriptor.symbolicTraits
            #expect(both.contains(.bold) && both.contains(.italic))

            // An image's "!" stands for the picture and the rest of its source is hidden; ImageTests has the rest.
            #expect(w.displayAttributes(at: offset("![alt]"))[.attachment] != nil)
            #expect(w.isHidden(offset("[alt]")) && w.isHidden(offset("alt")) && w.isHidden(offset("pic.png")))
        }

        @Test func headingsScaleAndOnlyTheFirstTwoLevelsAreRuled() {
            let w = EditorWindow("# one\n## two\n### three\n###### six\ntext\nmore\n")
            defer { w.close() }
            w.select(w.length)
            w.pump()
            let starts = [0, 6, 13, 23]
            let sizes = [4, 11, 21, 32].map { w.displayFont(at: $0).pointSize }
            #expect(sizes == [theme.headingSizes[0], theme.headingSizes[1], theme.headingSizes[2], theme.headingSizes[5]])
            #expect(sizes[0] > sizes[1] && sizes[1] > sizes[2] && sizes[2] > theme.bodySize)
            #expect(zip(theme.headingSizes, theme.headingSizes.dropFirst()).allSatisfy { $0 > $1 }, "every level is smaller than the one above")
            #expect(starts.map { w.displayAttributes(at: $0)[.hairline] != nil } == [true, true, false, false])
            #expect(starts.allSatisfy { w.fragment(at: $0) is BlockFragment })
            #expect(w.fragment(at: 0).renderingSurfaceBounds.width >= w.textView.textContainer!.size.width)
            #expect(w.displayFont(at: 35) == theme.bodyFont)
            #expect(w.fragment(at: 35).layoutFragmentFrame.height == theme.bodyLineHeight)
        }

        // MARK: reveal

        @Test func aTokenRevealsWhenTheSelectionTouchesEitherBoundary() {
            let w = EditorWindow("aa **b** cc\nnext\n")
            defer { w.close() }
            func revealed(_ location: Int, _ length: Int = 0) -> Bool {
                w.select(location, length: length)
                w.pump(0.01)
                return !w.isHidden(3) && !w.isHidden(7)
            }
            #expect(!revealed(2))
            #expect(revealed(3))
            #expect(revealed(5))
            #expect(revealed(8))
            #expect(!revealed(9))
            #expect(revealed(0, 3), "a selection ending at the token start touches it")
            #expect(!revealed(0, 2))
            #expect(revealed(8, 3))
            #expect(!revealed(13))
        }

        @Test func headingMarkersRevealWhileTheCaretIsOnTheLine() {
            let w = EditorWindow("x\n# H #\ny\n\nTitle\n=====\nz\n")
            defer { w.close() }
            func select(_ location: Int) {
                w.select(location)
                w.pump(0.01)
            }
            select(1)
            #expect(w.isHidden(2) && w.isHidden(3) && w.isHidden(5) && w.isHidden(6))
            select(2)
            #expect(!w.isHidden(2) && !w.isHidden(6))
            #expect(w.displayFont(at: 2) == theme.headingFont(level: 1), "revealed markers are full size")
            select(7)
            #expect(!w.isHidden(2))
            select(8)
            #expect(w.isHidden(2))

            // A setext underline is a hairline until the caret is on the heading or on it.
            #expect(w.isHidden(17) && w.displayAttributes(at: 17)[.rule] != nil)
            let collapsed = w.fragment(at: 17).layoutFragmentFrame, below = w.fragment(at: 23).layoutFragmentFrame
            #expect(collapsed.height == theme.underlineLineHeight)
            select(12)
            #expect(!w.isHidden(17) && w.displayAttributes(at: 17)[.rule] == nil)
            #expect(w.fragment(at: 17).layoutFragmentFrame.height == collapsed.height, "revealing it changes no height")
            #expect(w.fragment(at: 23).layoutFragmentFrame == below, "so nothing below moves")
            select(19)
            #expect(!w.isHidden(17))
            select(23)
            #expect(w.isHidden(17))
        }

        @Test func revealWaitsWhileAnInputMethodIsComposing() {
            let w = EditorWindow("**b** tail\nnext\n")
            defer { w.close() }
            w.select(5)
            w.pump(0.01)
            #expect(!w.isHidden(0))

            w.textView.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 5, length: 0))
            w.pump(0.01)
            #expect(w.textView.hasMarkedText())
            #expect(w.textView.selectedRange().location == 6)
            #expect(!w.isHidden(0) && !w.isHidden(4), "the caret left the token, but composition freezes the reveal")

            w.textView.insertText("日本", replacementRange: w.textView.markedRange())
            w.pump(0.01)
            #expect(!w.textView.hasMarkedText())
            #expect(w.textView.string == "**b**日本 tail\nnext\n")
            #expect(w.isHidden(0) && w.isHidden(4), "the commit catches up")
            w.undoAll()
            #expect(w.textView.string == "**b** tail\nnext\n")
        }

        // MARK: restyling

        @Test func anEditRestylesOtherLinesAndUndoRestylesThemBack() {
            let w = EditorWindow("intro\n\n**b** x\n\nend\n")
            defer { w.close() }
            #expect(w.isHidden(7) && w.displayFont(at: 9).fontDescriptor.symbolicTraits.contains(.bold))

            w.textView.insertText("```\n", replacementRange: NSRange(location: 0, length: 0))
            w.pump()
            #expect(!w.isHidden(11), "inside a code block the asterisks are code")
            #expect(w.displayFont(at: 13).fontDescriptor.symbolicTraits.contains(.monoSpace))

            w.textView.undoManager?.undo()
            w.pump()
            #expect(w.textView.string == "intro\n\n**b** x\n\nend\n")
            #expect(w.isHidden(7) && w.displayFont(at: 9).fontDescriptor.symbolicTraits.contains(.bold), "undo sends no textDidChange")

            w.textView.undoManager?.redo()
            w.pump()
            #expect(!w.isHidden(11))
        }

        // A reference to a link defined elsewhere can only be read with the whole text; a large text waits for that.

        @Test func aLargeDocumentReparsesWhenTypingPauses() {
            let filler = String(repeating: "some plain words on a line\n", count: 4000) + "\n[ref]: /url\n"
            #expect(filler.utf16.count > EditorController.synchronousParseLimit)
            let w = EditorWindow("[ref]\n\n**b** x\n" + filler)
            defer { w.close() }
            #expect(w.isHidden(7), "loading parses synchronously whatever the size")

            w.textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
            #expect(w.displayFont(at: 3) != theme.headingFont(level: 1), "the edited line is raw until the reparse")
            for _ in 0..<200 where w.displayFont(at: 3) != theme.headingFont(level: 1) { w.pump(0.05) }
            #expect(w.displayFont(at: 3) == theme.headingFont(level: 1))
            #expect(w.isHidden(9) && w.displayFont(at: 11).fontDescriptor.symbolicTraits.contains(.bold))
            #expect(w.storageProblem == nil)
        }

        @Test func aLargeDocumentIsParsedBeforeAKeyReadsTheMap() {
            let filler = String(repeating: "some plain words on a line\n", count: 4000) + "\n[ref]: /url\n"
            let w = EditorWindow("- [1]\n- two\n\n" + filler + "[1]: /url\n")
            defer { w.close() }
            w.select(5)
            w.type("x\r")
            #expect(w.textView.string.hasPrefix("- [1]x\n- \n- two\n"), "Return right after a character still continues the list")
            w.type("y")
            w.command(#selector(NSResponder.moveRight(_:)))
            #expect(w.textView.selectedRange() == NSRange(location: 13, length: 0), "and the arrow keys still skip the hidden markers")
            w.type("z" + String(EditorWindow.backspace) + String(EditorWindow.backspace))
            #expect(w.textView.string.hasPrefix("- [1]x\n- y\n\ntwo\n"), "as does Backspace")
            #expect(w.storageProblem == nil)
        }

        @Test func aStaleMapHidesNothing() {
            let filler = String(repeating: "some plain words on a line\n", count: 4000) + "\n[ref]: /url\n"
            let w = EditorWindow("*abc* [ref]\n\n" + filler)
            defer { w.close() }
            w.select(w.length)
            w.pump()
            #expect(w.isHidden(0) && w.isHidden(4))
            // The line keeps its length, so its range still matches the old map's line.
            w.textView.insertText("x", replacementRange: NSRange(location: 0, length: 1))
            #expect(!w.isHidden(0) && !w.isHidden(4), "raw until the reparse")
            #expect(w.displayAttributes(at: 0)[.glyphLift] == nil)
            for _ in 0..<200 where w.displayAttributes(at: 0)[.glyphLift] == nil { w.pump(0.05) }
            #expect(w.displayAttributes(at: 0)[.glyphLift] != nil && !w.isHidden(4), "then a paragraph with a literal asterisk")
        }

        // MARK: spelling

        @Test func spellingMarksAreSuppressedOnSyntaxAndCode() {
            let source = "wrogn [text](http://exampel.org) `kodde` tail\n\n```\nfrobnicat\n```\n\nfirst<br>secnod\n"
            let w = EditorWindow(source)
            defer { w.close() }
            #expect(w.textView.isContinuousSpellCheckingEnabled)
            #expect(w.textView.accessibilityLabel() == "Markdown text")
            func state(_ text: String) -> Int {
                w.editor.textView(w.textView, shouldSetSpellingState: 1, range: (source as NSString).range(of: text))
            }
            #expect(state("wrogn") == 1)
            #expect(state("text") == 1)
            #expect(state("tail") == 1)
            #expect(state("exampel") == 0)
            #expect(state("kodde") == 0)
            #expect(state("frobnicat") == 0)
            // A tag's name is no word: in a cell that wraps, the hidden "<br>" showed its mark as a dot.
            #expect(state("br") == 0 && state("secnod") == 1)
        }

        // MARK: renderer invariants

        @Test func everyFixtureRendersSameLengthParagraphsOverUntouchedPlainStorage() throws {
            let w = EditorWindow()
            defer { w.close() }
            #expect(Fixtures.all.count >= 13)
            for url in Fixtures.all {
                let name = url.lastPathComponent
                let source = try MarkdownFile(data: Data(contentsOf: url)).text
                w.editor.text = source
                w.select((source as NSString).length / 2)
                w.pump(0.02)
                w.layout.ensureLayout(for: w.layout.documentRange)

                // Only the stand-ins for block markers differ from the source, and only among those markers,
                // and the tabs that stand for a table's pipes.
                let standIns = Set(("\u{FFFC} \t" + theme.bulletGap + theme.bullets.joined()).utf16)
                var prefixes = IndexSet(), pipes = IndexSet(), rows = IndexSet()
                for line in MarkdownStyler.style(source).lines {
                    prefixes.insert(integersIn: Range(line.prefixRange)!)
                    for pipe in line.pipes { pipes.insert(pipe) }
                    if case .tableRow = line.kind { rows.insert(integersIn: Range(line.range)!) }
                }
                // In a table row whose cells wrap: a line separator for a pipe or a "<br>", and
                // characters without width for what is hidden.
                let wrapping = Set("\u{2028}\u{2060}\u{200C}".utf16)
                var paragraphs = 0, rendered = 0, end = 0
                w.content.enumerateTextElements(from: w.content.documentRange.location, options: []) { element in
                    let paragraph = element as! NSTextParagraph, range = paragraph.elementRange!
                    let start = w.content.offset(from: w.content.documentRange.location, to: range.location)
                    let length = w.content.offset(from: range.location, to: range.endLocation)
                    #expect(start == end, "\(name): paragraphs are contiguous")
                    #expect(paragraph.attributedString.length == length, "\(name) at \(start)")
                    let shown = Array(paragraph.attributedString.string.utf16)
                    let stored = Array((source as NSString).substring(with: NSRange(location: start, length: length)).utf16)
                    #expect(zip(shown, stored).enumerated().allSatisfy { index, units in
                        units.0 == units.1 || standIns.contains(units.0) && prefixes.contains(start + index)
                            || units.0 == 0x09 && pipes.contains(start + index)
                            || wrapping.contains(units.0) && rows.contains(start + index)
                            // The picture of an image stands where its "!" is.
                            || units.0 == 0xFFFC && units.1 == 0x21
                    }, "\(name) at \(start)")
                    paragraphs += 1
                    if length > 0, paragraph.attributedString.attribute(.glyphLift, at: 0, effectiveRange: nil) != nil { rendered += 1 }
                    end = start + length
                    return true
                }
                #expect(end == (source as NSString).length, "\(name)")
                #expect(rendered == paragraphs && paragraphs > 0, "\(name): \(rendered) of \(paragraphs) paragraphs came from the renderer")
                #expect(w.textView.string == source, "\(name)")
                #expect(w.storageProblem == nil, "\(name)")
                #expect(w.textView.textLayoutManager != nil, "\(name)")
            }
        }
    }
}
